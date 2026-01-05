// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "./vendor/@uniswap/v3-periphery/contracts/base/PeripheryPayments.sol";
import "./vendor/@uniswap/v3-periphery/contracts/base/PeripheryImmutableState.sol";
import "./vendor/@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./vendor/@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../CometInterface.sol";
import "../CometMainInterface.sol";
import "../ERC20.sol";
import "../IERC20NonStandard.sol";
import "../IWstETH.sol";
import "../univ3lp/interfaces/IUniV3LPVault.sol";
import "../univ3lp/interfaces/uniswap/IUniswapV3PositionManager.sol";
import "./interfaces/IStableSwap.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IVault.sol";
import "../vendor/access/Ownable.sol";

/// @title Minimal ERC721 receiver interface
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/// @title LiquidityRouter interface for Perp LP operations
interface ILiquidityRouter {
    function minExecutionFee() external view returns (uint256);
    function createWithdrawal(
        address _poolToken,
        address _token,
        uint256 _lpAmount,
        uint256 _minOut,
        address _receiver,
        uint256 _executionFee
    ) external payable returns (bytes32);
}

/**
 * @title LiquidationRouter (No Flash Loan Version)
 * @notice 零资金清算路由合约，不使用闪电贷，直接将抵押品转给清算合约
 * @dev 实现"先 seize 再 swap 再 repay"的清算流程
 * 
 * 核心特性：
 * - 不使用闪电贷：完全摒弃闪电贷逻辑
 * - 直接接收抵押品：absorb 后抵押品（ERC20 和 NFT）直接转给清算合约
 * - 协议自行清算：清算产生的所有 base token 归协议所有
 * - 清算合约无利润：清算合约本身不获得任何利润
 * - NFT 支持：可以接收和处理 NFT 抵押品
 * 
 * 清算流程：
 * 1. 调用 Comet.absorb() - 抵押品（ERC20 和 NFT）直接转给清算合约
 * 2. 清算合约收到抵押品后，直接 swap 成 base token
 *    - ERC20: 直接 swap
 *    - NFT: 提取流动性后 swap
 * 3. 将所有 base token 返还到协议
 */
contract LiquidationRouter is 
    IERC721Receiver,
    PeripheryImmutableState,
    PeripheryPayments,
    Ownable
{
    /// @notice Reentrancy guard flag
    bool private _entered;

    modifier nonReentrant() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }

    /** Errors */
    error InsufficientAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutMin
    );
    error InvalidArgument();
    error InvalidExchange();
    error InvalidPoolConfig(address swapToken);

    /** Events */
    event LiquidationExecuted(
        address indexed caller,
        address[] accounts,
        uint256 totalBaseReturned
    );
    event CollateralReceived(
        address indexed asset,
        uint256 amount
    );
    event PreProcessSPLP(
        address indexed caller,
        address indexed asset
    );
    event ProcessedSPLP(
        address indexed caller,
        address indexed asset,
        uint256 amount
    );
    event CollateralSwapped(
        address indexed asset,
        uint256 collateralAmount,
        uint256 baseAmount
    );
    event BaseTokenReturned(
        address indexed comet,
        uint256 amount
    );
    event NFTReceived(
        address indexed nftPositionManager,
        uint256 indexed tokenId,
        address indexed vault
    );
    event CreateWithdrawalSuccess(
        address indexed asset,
        address indexed baseToken,
        uint256 lpBalance,
        uint256 minOut,
        address indexed receiver,
        uint256 executionFee
    );

    /// @notice 更新 Perp LP 滑点参数事件
    event PerpLPSlippageUpdated(uint256 oldSlippageBps, uint256 newSlippageBps);

    enum Exchange {
        Uniswap,
        SushiSwap,
        Balancer,
        Curve
    }

    struct PoolConfig {
        Exchange exchange;      // 使用的交易所
        uint24 uniswapPoolFee;  // Uniswap pool fee (3000, 500, 100)
        bool swapViaWeth;       // 是否通过 WETH 中转
        bytes32 balancerPoolId; // Balancer pool ID
        address curvePool;      // Curve pool 地址
    }
    
    /// @notice Uniswap Router 地址
    address public immutable uniswapRouter;

    /// @notice LiquidityRouter 合约地址（用于 Perp LP 操作）
    address public immutable liquidityRouter;

    /// @notice Perp LP token 地址（可配置）
    address public immutable perpLPToken;

    /// @notice Perp LP withdrawal 滑点保护（basis points，例如 50 = 0.5%）
    uint256 public perpLPSlippageBasisPoints;

    /// @notice Basis points divisor (10000)
    uint256 private constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice 当前清算过程中收到的 NFT tokenIds（按 vault 地址分组）
    mapping(address => uint256[]) public receivedNFTs;
    
    /// @notice Pending withdrawal requests (requestKey => expected base token amount)
    mapping(bytes32 => uint256) public pendingWithdrawals;
    
    /// @notice Pending withdrawal requestKeys 列表（用于后续处理）
    bytes32[] private pendingWithdrawalKeys;
    
    /// @notice 每个 pending withdrawal 对应的 Comet 地址（用于返还 base token）
    mapping(bytes32 => address) private pendingWithdrawalComets;

    /// @notice Pending NFT 处理请求（vault => PendingNFTInfo）
    struct PendingNFTInfo {
        address comet;           // Comet 协议地址
        PoolConfig poolConfig;   // Swap 配置
        uint256[] tokenIds;      // 待处理的 tokenIds
    }
    
    /// @notice Pending NFT 信息（按 vault 地址分组）
    mapping(address => PendingNFTInfo) public pendingNFTs;
    
    /// @notice Pending NFT vault 地址列表（用于后续处理）
    address[] private pendingNFTVaults;

    /// @notice 初始化标志（用于代理部署）
    bool private _initialized;

    /**
     * @notice 构造函数
     * @dev 直接部署时，部署者自动成为 owner
     */
    constructor(
        address uniswapRouter_,
        address uniswapV3Factory_,
        address WETH9_,
        address liquidityRouter_,
        address perpLPToken_,
        uint256 perpLPSlippageBasisPoints_
    ) PeripheryImmutableState(uniswapV3Factory_, WETH9_) {
        uniswapRouter = uniswapRouter_;
        liquidityRouter = liquidityRouter_;
        perpLPToken = perpLPToken_;
        require(perpLPSlippageBasisPoints_ <= BASIS_POINTS_DIVISOR, "Invalid slippage");
        perpLPSlippageBasisPoints = perpLPSlippageBasisPoints_;
        
        // 直接部署时，标记为已初始化，部署者自动成为 owner（通过 Ownable 构造函数）
        _initialized = true;
    }

    /**
     * @notice 更新 Perp LP withdrawal 滑点保护
     * @param newSlippageBps 新的滑点（basis points，10000=100%）
     * @dev 只有 owner 可调用
     */
    function setPerpLPSlippageBasisPoints(uint256 newSlippageBps) external onlyOwner {
        require(newSlippageBps <= BASIS_POINTS_DIVISOR, "Invalid slippage");
        uint256 old = perpLPSlippageBasisPoints;
        perpLPSlippageBasisPoints = newSlippageBps;
        emit PerpLPSlippageUpdated(old, newSlippageBps);
    }

    /**
     * @notice 初始化函数（用于代理部署）
     * @param newOwner 新的 owner 地址
     * @dev 只能调用一次，用于在代理部署时设置 owner
     *      直接部署时不需要调用此函数（构造函数已处理）
     */
    function initialize(address newOwner) external {
        require(!_initialized, "ALREADY_INITIALIZED");
        require(newOwner != address(0), "INVALID_OWNER");
        
        _initialized = true;
        _transferOwnership(newOwner);
    }

    /**
     * @notice 执行零资金清算（不使用闪电贷版本）
     * @param comet Comet 协议地址
     * @param liquidatableAccounts 可清算的账户列表
     * @param collateralAssets 要清算的抵押品资产列表
     * @param poolConfigs 每个资产的 swap 配置
     * @dev 只有 owner 可以调用此函数
     */
    function liquidate(
        address comet,
        address[] calldata liquidatableAccounts,
        address[] calldata collateralAssets,
        PoolConfig[] calldata poolConfigs
    ) external payable onlyOwner nonReentrant {
        if (collateralAssets.length != poolConfigs.length) revert InvalidArgument();

        CometInterface cometContract = CometInterface(comet);
        address baseToken = cometContract.baseToken();

        // 清空之前收到的 NFT 记录
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            if (isUniV3LPVault(collateralAssets[i])) {
                delete receivedNFTs[collateralAssets[i]];
            }
        }

        // 步骤 1: 调用 Comet.absorb() - 抵押品（ERC20 和 NFT）直接转给本合约
       try cometContract.absorb(address(this), liquidatableAccounts) {} catch {}

        // 步骤 2: 将收到的抵押品 swap 成 base token
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            address asset = collateralAssets[i];
            
            // 检查是否是 UniV3LPVault（NFT 资产）
            if (isUniV3LPVault(asset)) {
                // NFT 资产：只接收，不立即处理（异步处理，避免 gas 不足）
                // 将 NFT 信息存储为 pending，后续通过 processPendingNFTs() 处理
                uint256[] memory tokenIds = receivedNFTs[asset];
                if (tokenIds.length > 0) {
                    // 检查是否已存在 pending NFT 信息
                    bool isNewPending = pendingNFTs[asset].comet == address(0);
                    
                    if (isNewPending) {
                        // 新的 pending NFT，添加到列表
                        pendingNFTVaults.push(asset);
                    }
                    
                    // 合并 tokenIds（如果已存在）
                    if (isNewPending) {
                        // 新的 pending NFT，直接创建
                        pendingNFTs[asset] = PendingNFTInfo({
                            comet: comet,
                            poolConfig: poolConfigs[i],
                            tokenIds: tokenIds
                        });
                    } else {
                        // 已存在，合并 tokenIds
                        uint256[] storage existingTokenIds = pendingNFTs[asset].tokenIds;
                        for (uint256 j = 0; j < tokenIds.length; j++) {
                            existingTokenIds.push(tokenIds[j]);
                        }
                        // 更新 comet 和 poolConfig（确保是最新的）
                        pendingNFTs[asset].comet = comet;
                        pendingNFTs[asset].poolConfig = poolConfigs[i];
                    }
                    
                    emit NFTReceived(address(0), 0, asset); // 标记为 pending
                }
            } else if (isPerpLPToken(asset)) {
                emit PreProcessSPLP(msg.sender, asset);
                // 处理 Perp LP token：通过 LiquidityRouter.createWithdrawal 赎回流动性
                processPerpLPToken(asset, comet);
            } else {
                // 处理普通 ERC20 资产：直接 swap
                uint256 collateralBalance = ERC20(asset).balanceOf(address(this));
                
                if (collateralBalance == 0) continue;

                emit CollateralReceived(asset, collateralBalance);

                // 将抵押品 swap 成 base token
                uint256 baseAmountOut = swapCollateral(
                    comet,
                    asset,
                    collateralBalance,
                    poolConfigs[i]
                );

                emit CollateralSwapped(asset, collateralBalance, baseAmountOut);
            }
        }

        // 步骤 4: 将所有 base token 返还到协议
        uint256 baseBalance = ERC20(baseToken).balanceOf(address(this));
        
        if (baseBalance > 0) {
            TransferHelper.safeApprove(baseToken, address(this), baseBalance);
            pay(baseToken, address(this), comet, baseBalance);
            
            emit BaseTokenReturned(comet, baseBalance);
        }

        emit LiquidationExecuted(
            msg.sender,
            liquidatableAccounts,
            baseBalance
        );
    }

    /**
     * @notice 处理 NFT 资产：提取流动性并 swap 成 base token
     * @dev 内部函数，用于实际处理 NFT
     */
    function processNFTAsset(
        address vault,
        address comet,
        PoolConfig memory poolConfig
    ) internal {
        IUniV3LPVault vaultContract = IUniV3LPVault(vault);
        address nftPositionManager = vaultContract.nftPositionManager();
        uint256[] memory tokenIds = receivedNFTs[vault];
        
        if (tokenIds.length == 0) return;
        
        address baseToken = CometInterface(comet).baseToken();
        IUniswapV3PositionManager positionManager = IUniswapV3PositionManager(nftPositionManager);
        
        // 处理每个 NFT
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // 获取 position 信息
            (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = 
                positionManager.positions(tokenId);
            
            if (liquidity == 0) continue;
            
            // 提取所有流动性
            positionManager.decreaseLiquidity(
                IUniswapV3PositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            
            // 收集 token0 和 token1
            (uint256 amount0, uint256 amount1) = positionManager.collect(
                IUniswapV3PositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            
            // 将 token0 和 token1 swap 成 base token
            if (amount0 > 0) {
                swapTokenToBase(token0, baseToken, amount0, poolConfig);
            }
            if (amount1 > 0) {
                swapTokenToBase(token1, baseToken, amount1, poolConfig);
            }
        }
        
        // 清空已处理的 NFT 记录
        delete receivedNFTs[vault];
    }

    /**
     * @notice 将任意 token swap 成 base token
     */
    function swapTokenToBase(
        address tokenIn,
        address baseToken,
        uint256 amountIn,
        PoolConfig memory poolConfig
    ) internal {
        if (tokenIn == baseToken) {
            return;
        }
        
        if (poolConfig.exchange == Exchange.Uniswap) {
            swapViaUniswap(tokenIn, baseToken, amountIn, poolConfig);
        } else {
            revert InvalidExchange();
        }
    }

    /**
     * @notice 将抵押品 swap 成 base token（仅用于 ERC20 资产）
     */
    function swapCollateral(
        address comet,
        address asset,
        uint256 collateralAmount,
        PoolConfig memory poolConfig
    ) internal returns (uint256 amountOut) {
        address baseToken = CometInterface(comet).baseToken();

        if (poolConfig.exchange == Exchange.Uniswap) {
            return swapViaUniswap(asset, baseToken, collateralAmount, poolConfig);
        } else {
            revert InvalidExchange();
        }
    }

    /**
     * @notice 检查是否是 UniV3LPVault
     */
    function isUniV3LPVault(address asset) internal view returns (bool) {
        (bool success, bytes memory result) = asset.staticcall{gas: 30000}(
            abi.encodeWithSelector(IUniV3LPVault.isUniV3LPVault.selector)
        );
        if (!success || result.length < 32) {
            return false;
        }
        return abi.decode(result, (bool));
    }

    /**
     * @notice 检查是否是 Perp LP token
     */
    function isPerpLPToken(address asset) internal view returns (bool) {
        return perpLPToken != address(0) && asset == perpLPToken;
    }

    /**
     * @notice 处理 Perp LP token：通过 LiquidityRouter.createWithdrawal 赎回流动性
     * @param asset Perp LP token 地址
     * @param comet Comet 协议地址
     * @dev 调用 LiquidityRouter.createWithdrawal 异步赎回流动性
     *      由于是异步的，需要等待 keeper 执行后 base token 才会到账
     */
    function processPerpLPToken(address asset, address comet) internal {
        require(asset == perpLPToken, "Not Perp LP token");
        require(liquidityRouter != address(0), "LiquidityRouter not set");
        require(perpLPToken != address(0), "PerpLPToken not set");

        CometMainInterface cometContract = CometMainInterface(comet);
        address baseToken = cometContract.baseToken();
        
        uint256 lpBalance = ERC20(asset).balanceOf(address(this));
        if (lpBalance == 0) return;

        emit CollateralReceived(asset, lpBalance);

        ILiquidityRouter router = ILiquidityRouter(liquidityRouter);
        uint256 executionFee = router.minExecutionFee();
        
        // 确保有足够的 ETH 支付执行费用（msg.value + 合约余额）
        // msg.value 会在交易中自动添加到合约余额，所以检查总和
        require(msg.value + address(this).balance >= executionFee, "Insufficient ETH for execution fee");

        // 计算最小输出（使用 Comet 的价格计算）
        // 获取 Perp LP 资产信息
        CometMainInterface.AssetInfo memory perpLPAssetInfo = cometContract.getAssetInfoByAddress(asset);
        
        // 获取价格
        uint256 basePrice = cometContract.getPrice(cometContract.baseTokenPriceFeed());
        uint256 perpLPPrice = cometContract.getPrice(perpLPAssetInfo.priceFeed);
        
        // 计算预期的 base token 数量
        // estimatedBaseAmount = (lpBalance * perpLPPrice * baseScale) / (perpLPScale * basePrice)
        uint256 baseScale = cometContract.baseScale();
        uint256 estimatedBaseAmount = (lpBalance * perpLPPrice * baseScale) / (perpLPAssetInfo.scale * basePrice);
        
        // 应用滑点保护：minOut = estimatedBaseAmount * (10000 - slippageBasisPoints) / 10000
        uint256 minOut = estimatedBaseAmount * (BASIS_POINTS_DIVISOR - perpLPSlippageBasisPoints) / BASIS_POINTS_DIVISOR;

        // 批准 LiquidityRouter 使用 LP tokens
        TransferHelper.safeApprove(asset, liquidityRouter, lpBalance);

        // 调用 createWithdrawal（异步）
        // 参数：
        // - _poolToken: Perp LP token 地址
        // - _token: base token 地址（要换取的资产）
        // - _lpAmount: LP token 数量
        // - _minOut: 最小输出（base token）
        // - _receiver: 接收者（本合约地址）
        // - _executionFee: 执行费用（ETH）
        bytes32 requestKey = router.createWithdrawal{value: executionFee}(
            asset,          // _poolToken
            baseToken,      // _token
            lpBalance,      // _lpAmount
            minOut,         // _minOut
            address(this),  // _receiver
            executionFee    // _executionFee
        );

        emit CreateWithdrawalSuccess(asset, baseToken, lpBalance, minOut,  address(this), executionFee);
        // 存储 pending withdrawal 信息
        pendingWithdrawals[requestKey] = minOut;
        pendingWithdrawalKeys.push(requestKey);
        pendingWithdrawalComets[requestKey] = comet;

        // 注意：withdrawal 是异步的，keeper 会在后续交易中执行
        // base token 会在 keeper 执行后转到本合约
        // 需要调用 processPendingWithdrawals() 来处理已完成的 withdrawals
        emit ProcessedSPLP(msg.sender, asset, minOut);
    }

    /**
     * @notice ERC721 接收回调，用于接收 NFT
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        // msg.sender 是 NFT Position Manager 合约
        // from 是 UniV3LPVault 地址
        address vault = from;
        
        receivedNFTs[vault].push(tokenId);
        
        emit NFTReceived(msg.sender, tokenId, vault);
        
        return IERC721Receiver.onERC721Received.selector;
    }

    // Swap 函数实现
    function swapViaUniswap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        PoolConfig memory poolConfig
    ) internal returns (uint256 amountOut) {
        uint24 poolFee = poolConfig.uniswapPoolFee;
        if (poolFee == 0) {
            revert InvalidPoolConfig(tokenIn);
        }

        TransferHelper.safeApprove(tokenIn, address(uniswapRouter), amountIn);

        address swapToken = tokenIn;
        uint256 swapAmount = amountIn;

        if (poolConfig.swapViaWeth) {
            swapAmount = ISwapRouter(uniswapRouter).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: WETH9,
                    fee: poolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
            swapToken = WETH9;
            poolFee = 500;
            TransferHelper.safeApprove(WETH9, address(uniswapRouter), swapAmount);
        }

        amountOut = ISwapRouter(uniswapRouter).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: swapToken,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    
    /**
     * @notice 处理已完成的 pending withdrawals 并返还 base token 给协议
     * @param comet Comet 协议地址
     * @dev 直接将所有收到的 base token 返还给对应的 Comet 协议
     *      不通过 requestKey 匹配，因为无法准确判断余额增加对应的是哪个 requestKey
     *      这个函数可以被任何人调用，用于处理已完成的 withdrawals
     */
    function processPendingWithdrawals(address comet) external onlyOwner nonReentrant {
        // 获取 Comet 的 base token 地址
        CometInterface cometContract = CometInterface(comet);
        address baseToken = cometContract.baseToken();
        
        // 获取当前 base token 余额
        uint256 baseBalance = ERC20(baseToken).balanceOf(address(this));
        
        // 如果有余额，返还给 Comet 协议
        if (baseBalance > 0) {
            TransferHelper.safeApprove(baseToken, address(this), baseBalance);
            pay(baseToken, address(this), comet, baseBalance);
            
            emit BaseTokenReturned(comet, baseBalance);
            emit LiquidationExecuted(msg.sender, new address[](0), baseBalance);
        }
        
        // 清理所有 pending withdrawal 记录（因为我们已经返还了所有余额）
        // 注意：这里我们清理所有记录，因为无法准确匹配哪个 requestKey 已完成
        // 如果某些 withdrawal 还未完成（keeper 还未执行），它们的 pending 记录会被清理
        // 但当这些 withdrawal 完成时，base token 会到账，下次调用 processPendingWithdrawals()
        // 时会自动返还这些 base token（因为我们返还所有余额，不依赖 pending 记录）
        uint256 keysLength = pendingWithdrawalKeys.length;
        for (uint256 i = 0; i < keysLength; i++) {
            bytes32 requestKey = pendingWithdrawalKeys[pendingWithdrawalKeys.length - 1];
            delete pendingWithdrawals[requestKey];
            delete pendingWithdrawalComets[requestKey];
            pendingWithdrawalKeys.pop();
        }
    }



    /**
     * @notice 处理已接收的 pending NFTs：提取流动性并 swap 成 base token
     * @dev 检查所有 pending NFTs，如果已接收，则处理并返还 base token 给协议
     *      这个函数可以被任何人调用，用于处理已接收的 NFTs
     * @param vaults 要处理的 vault 地址列表（空数组表示处理所有）
     */
    function processPendingNFTs(address[] calldata vaults) external onlyOwner nonReentrant {
        uint256 totalBaseReturned = 0;
        
        // 从后往前遍历，以便安全删除元素
        uint256 i = pendingNFTVaults.length;
        while (i > 0) {
            i--;
            address vault = pendingNFTVaults[i];
            
            // 如果指定了 vaults，只处理指定的 vaults
            if (vaults.length > 0) {
                bool shouldProcess = false;
                for (uint256 j = 0; j < vaults.length; j++) {
                    if (vaults[j] == vault) {
                        shouldProcess = true;
                        break;
                    }
                }
                if (!shouldProcess) {
                    continue;
                }
            }
            
            PendingNFTInfo memory nftInfo = pendingNFTs[vault];
            
            // 如果 vault 没有 pending NFT 信息，跳过
            if (nftInfo.comet == address(0) || nftInfo.tokenIds.length == 0) {
                // 清理无效的 vault
                if (i < pendingNFTVaults.length - 1) {
                    pendingNFTVaults[i] = pendingNFTVaults[pendingNFTVaults.length - 1];
                }
                pendingNFTVaults.pop();
                continue;
            }
            
            // 处理 NFT：提取流动性并 swap
            address baseToken = CometInterface(nftInfo.comet).baseToken();
            uint256 balanceBefore = ERC20(baseToken).balanceOf(address(this));
            
            // 调用内部处理函数
            _processNFTAssetInternal(vault, nftInfo.comet, nftInfo.poolConfig, nftInfo.tokenIds);
            
            uint256 balanceAfter = ERC20(baseToken).balanceOf(address(this));
            uint256 baseReturned = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
            
            if (baseReturned > 0) {
                // 返还 base token 给协议
                TransferHelper.safeApprove(baseToken, address(this), baseReturned);
                pay(baseToken, address(this), nftInfo.comet, baseReturned);
                
                emit BaseTokenReturned(nftInfo.comet, baseReturned);
                totalBaseReturned += baseReturned;
            }
            
            // 清理 pending NFT 记录
            delete pendingNFTs[vault];
            
            // 从数组中删除（从后往前删除，避免索引问题）
            if (i < pendingNFTVaults.length - 1) {
                pendingNFTVaults[i] = pendingNFTVaults[pendingNFTVaults.length - 1];
            }
            pendingNFTVaults.pop();
        }
        
        // 如果处理了任何 NFT，发出事件
        if (totalBaseReturned > 0) {
            emit LiquidationExecuted(msg.sender, new address[](0), totalBaseReturned);
        }
    }
    
    /**
     * @notice 内部函数：处理 NFT 资产（提取流动性并 swap）
     * @param vault Vault 地址
     * @param comet Comet 协议地址
     * @param poolConfig Swap 配置
     * @param tokenIds 要处理的 tokenIds
     */
    function _processNFTAssetInternal(
        address vault,
        address comet,
        PoolConfig memory poolConfig,
        uint256[] memory tokenIds
    ) internal {
        if (tokenIds.length == 0) return;
        
        IUniV3LPVault vaultContract = IUniV3LPVault(vault);
        address nftPositionManager = vaultContract.nftPositionManager();
        address baseToken = CometInterface(comet).baseToken();
        IUniswapV3PositionManager positionManager = IUniswapV3PositionManager(nftPositionManager);
        
        // 处理每个 NFT
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // 检查 NFT 是否属于本合约
            try positionManager.ownerOf(tokenId) returns (address owner) {
                if (owner != address(this)) {
                    continue; // NFT 不属于本合约，跳过
                }
            } catch {
                continue; // 无法获取 owner，跳过
            }
            
            // 获取 position 信息
            (,, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = 
                positionManager.positions(tokenId);
            
            if (liquidity == 0) continue;
            
            // 提取所有流动性
            positionManager.decreaseLiquidity(
                IUniswapV3PositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            
            // 收集 token0 和 token1
            (uint256 amount0, uint256 amount1) = positionManager.collect(
                IUniswapV3PositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            
            // 将 token0 和 token1 swap 成 base token
            if (amount0 > 0) {
                swapTokenToBase(token0, baseToken, amount0, poolConfig);
            }
            if (amount1 > 0) {
                swapTokenToBase(token1, baseToken, amount1, poolConfig);
            }
        }
    }
    
    /**
     * @notice 获取 pending NFT vaults 数量
     * @return 待处理的 vault 数量
     */
    function getPendingNFTVaultsCount() external view returns (uint256) {
        return pendingNFTVaults.length;
    }
    
    /**
     * @notice 获取指定索引的 pending NFT vault 地址
     * @param index 索引
     * @return vault 地址
     */
    function getPendingNFTVault(uint256 index) external view returns (address) {
        require(index < pendingNFTVaults.length, "Index out of bounds");
        return pendingNFTVaults[index];
    }

    receive() external payable {}
}
