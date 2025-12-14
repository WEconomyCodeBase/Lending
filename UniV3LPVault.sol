// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "../IERC20Metadata.sol";
import "../vendor/access/Ownable.sol";
import "./interfaces/INFTLP.sol";
import "./interfaces/IUniV3LPVault.sol";
import "./libraries/LiquidityAmounts.sol";
import "./libraries/FullMath.sol";
import "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Minimal interfaces
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

// Minimal Comet interface for supplyFrom, withdrawFrom and hasPermission
interface IComet {
    function supplyFrom(address from, address dst, address asset, uint256 amount) external;
    function withdrawFrom(address src, address to, address asset, uint256 amount) external;
    function hasPermission(address owner, address manager) external view returns (bool);
    function withdrawCollateralWithTokenId(address src, address to, address asset, uint256 tokenId) external;
}

/**
 * @title UniV3LPVault
 * @notice Production-grade ERC20 vault that wraps Uniswap V3 LP NFT positions
 * @dev Users deposit Uniswap V3 NFT positions and receive ERC20 vault tokens
 *      The vault aggregates multiple NFT positions into a single ERC20 token
 *      Uses Chainlink price feeds for accurate USD valuation
 *      Note: Following impermax-v3-core's conservative approach, unclaimed fees are NOT included in valuation
 */
contract UniV3LPVault is IERC20Metadata, IUniV3LPVault, Ownable {
    
    /// @notice The Uniswap V3 NFT Position Manager contract
    address public immutable nftPositionManager;
    
    /// @notice The NFTLP contract that manages the positions
    address public immutable nftlp;
    
    /// @notice Chainlink price feed for token0 (USD denominated)
    address public immutable token0PriceFeed;
    
    /// @notice Chainlink price feed for token1 (USD denominated)
    address public immutable token1PriceFeed;
    
    /// @notice Decimals of token0
    uint8 public immutable token0Decimals;
    
    /// @notice Decimals of token1
    uint8 public immutable token1Decimals;
    
    /// @notice Token name
    string public name;
    
    /// @notice Token symbol
    string public symbol;
    
    /// @notice Token decimals (18)
    uint8 public constant decimals = 18;
    
    /// @notice Total supply of vault tokens
    uint256 public totalSupply;
    
    /// @notice Balance mapping
    mapping(address => uint256) public balanceOf;
    
    /// @notice Allowance mapping
    mapping(address => mapping(address => uint256)) public allowance;
    
    /// @notice Total USD value of all positions (in 18 decimals)
    uint256 public totalValue;
    
    /// @notice Mapping from NFT tokenId to the amount of vault tokens it represents
    mapping(uint256 => uint256) public positionShares;
    
    /// @notice Mapping from tokenId to the user who deposited it
    mapping(uint256 => address) public positionOwner;
    
    /// @notice Mapping from user to array of tokenIds they deposited
    mapping(address => uint256[]) public userPositions;
    
    /// @notice Mapping from tokenId to its index in userPositions array
    mapping(uint256 => uint256) public positionIndexInUserArray;
    
    /// @notice Total number of NFT positions in the vault
    uint256 public totalPositions;
    
    /// @notice Mapping from position index to tokenId
    mapping(uint256 => uint256) public positionIds;
    
    /// @notice Mapping from tokenId to position index (0 means not in vault)
    mapping(uint256 => uint256) public positionIndex;
    
    /// @notice Comet contract address (for allowing transfers to Compound V3)
    address public cometAddress;
    
    /// @notice Minimum shares to prevent dust
    uint256 public constant MIN_SHARES = 1e6; // 0.000001 shares
    
    /// @notice Structure to represent a user position with its value
    struct UserPosition {
        uint256 tokenId;
        uint256 value; // USD value in 18 decimals
    }
    
    /// @notice Reentrancy guard
    bool private _locked;
    
    /// @notice Initialization guard for proxy deployments
    bool private _initialized;
    
    /// @notice Constants
    uint256 private constant Q96 = 2**96;
    uint256 private constant Q192 = 2**192;
    
    event Deposit(address indexed user, uint256 indexed tokenId, uint256 shares, uint256 positionValue);
    event Withdraw(address indexed user, uint256 indexed tokenId, uint256 shares);
    event Sync(uint256 totalValue);
    event CometAddressUpdated(address oldCometAddress, address newCometAddress);
    event LiquidateTransferNFT(address indexed liquidator, uint256 indexed tokenId, uint256 shares);
    event VaultMetadataUpdated(string oldName, string oldSymbol, string newName, string newSymbol);
    
    modifier nonReentrant() {
        require(!_locked, "ReentrancyGuard: reentrant call");
        _locked = true;
        _;
        _locked = false;
    }
    
    /**
     * @notice Construct a new UniV3LP Vault
     * @param _nftPositionManager The Uniswap V3 NonfungiblePositionManager address
     * @param _nftlp The NFTLP contract address that manages positions
     * @param _token0PriceFeed Chainlink price feed for token0 (USD)
     * @param _token1PriceFeed Chainlink price feed for token1 (USD)
     * @param _token0Decimals Decimals of token0
     * @param _token1Decimals Decimals of token1
     * @param name_ Name of the vault token
     * @param symbol_ Symbol of the vault token
     */
    constructor(
        address _nftPositionManager,
        address _nftlp,
        address _token0PriceFeed,
        address _token1PriceFeed,
        uint8 _token0Decimals,
        uint8 _token1Decimals,
        string memory name_,
        string memory symbol_
    ) {
        require(_nftPositionManager != address(0), "Invalid NFT Position Manager");
        require(_nftlp != address(0), "Invalid NFTLP");
        require(_token0PriceFeed != address(0), "Invalid token0 price feed");
        require(_token1PriceFeed != address(0), "Invalid token1 price feed");
        
        nftPositionManager = _nftPositionManager;
        nftlp = _nftlp;
        token0PriceFeed = _token0PriceFeed;
        token1PriceFeed = _token1PriceFeed;
        token0Decimals = _token0Decimals;
        token1Decimals = _token1Decimals;
        name = name_;
        symbol = symbol_;
        _initialized = true;
    }

    /**
     * @notice Initialize storage when using the contract behind a proxy
     * @param newOwner The address that should become the owner
     * @param newCometAddress Comet contract address to allow share transfers/liquidations
     * @param name_ Vault token name
     * @param symbol_ Vault token symbol
     * @dev Can only be called once; direct deployments via the constructor mark the contract as initialized
     */
    function initialize(
        address newOwner,
        address newCometAddress,
        string memory name_,
        string memory symbol_
    ) external {
        require(!_initialized, "ALREADY_INITIALIZED");
        require(newOwner != address(0), "INVALID_OWNER");
        require(bytes(name_).length != 0, "INVALID_NAME");
        require(bytes(symbol_).length != 0, "INVALID_SYMBOL");
        _initialized = true;
        _transferOwnership(newOwner);
        name = name_;
        symbol = symbol_;
        
        if (newCometAddress != address(0)) {
            cometAddress = newCometAddress;
        }
    }

    /**
     * @notice Update vault token metadata (name & symbol)
     * @param name_ New token name
     * @param symbol_ New token symbol
     * @dev Only callable by owner; allows proxy deployments to define ERC20 metadata post-initialization
     */
    function setVaultMetadata(string memory name_, string memory symbol_) external onlyOwner {
        require(bytes(name_).length != 0, "INVALID_NAME");
        require(bytes(symbol_).length != 0, "INVALID_SYMBOL");
        string memory oldName = name;
        string memory oldSymbol = symbol;
        name = name_;
        symbol = symbol_;
    }
    
    /**
     * @notice Internal mint function
     */
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    /**
     * @notice Internal burn function
     */
    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
    
    /**
     * @notice Transfer tokens
     * @dev Shares are non-transferable except to Comet contract (for Compound V3 integration)
     *      This ensures one tokenId can only be held by one user
     */
    function transfer(address to, uint256 amount) external override returns (bool) {
        // Allow Comet contract to transfer to any address (needed for liquidation payouts)
        if (msg.sender != cometAddress) {
            // Otherwise, only allow transfers to Comet contract or vault itself (for internal ops)
            require(to == cometAddress || to == address(this), "Shares can only be transferred to Comet or vault");
        }
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    /**
     * @notice Transfer from
     * @dev Shares are non-transferable except to Comet contract (for Compound V3 integration)
     *      This ensures one tokenId can only be held by one user
     */
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        // Allow Comet contract (either as sender or as the source of funds) to transfer to any address
        if (msg.sender != cometAddress && from != cometAddress) {
            // Otherwise, only allow transfers to Comet contract or vault itself (for internal ops)
            require(to == cometAddress || to == address(this), "Shares can only be transferred to Comet or vault");
        }
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    /**
     * @notice Approve
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    
    /**
     * @notice Get the exchange rate (totalValue / totalSupply)
     * @return The exchange rate in 18 decimals
     */
    function exchangeRate() public view returns (uint256) {
        if (totalSupply == 0 || totalValue == 0) {
            return 1e18; // 1:1 initial rate
        }
        return (totalValue * 1e18) / totalSupply;
    }
    
    /**
     * @notice Deposit a Uniswap V3 NFT position and directly supply to Comet in one transaction
     * @param tokenId The NFT token ID to deposit
     * @param account The account to supply collateral to in Comet (usually msg.sender)
     * @return shares The amount of vault tokens minted and supplied
     * @dev This function combines deposit and supply to Comet in a single call
     *      Requires Comet to be set and the vault to be approved by the user
     *      Shares are minted to the user, then transferred to Comet and supplied
     */
    function depositAndSupplyToComet(uint256 tokenId, address account) external nonReentrant returns (uint256 shares) {
        require(cometAddress != address(0), "Comet address not set");
        require(IERC721(nftPositionManager).ownerOf(tokenId) == msg.sender, "Not owner of NFT");
        require(account != address(0), "Invalid account");
        
        // Check if tokenId has already been deposited by another user
        require(positionOwner[tokenId] == address(0), "TokenId already deposited by another user");
        
        // Get position data from NFTLP
        (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
        
        // Calculate position value in USD using Chainlink price feeds
        uint256 positionValue = _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
        require(positionValue > 0, "Position has no value");
        require(positionValue >= MIN_SHARES, "Position value too small");
        
        // Calculate shares to mint based on exchange rate
        uint256 currentRate = exchangeRate();
        if (currentRate == 1e18 || totalSupply == 0) {
            shares = positionValue;
        } else {
            shares = (positionValue * 1e18) / currentRate;
        }
        
        require(shares > 0, "Shares too small");
        
        // Transfer NFT from user to vault
        IERC721(nftPositionManager).safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Record tokenId owner
        positionOwner[tokenId] = account;
        
        // Add to user's tokenId list
        userPositions[account].push(tokenId);
        positionIndexInUserArray[tokenId] = userPositions[account].length - 1;
        
        // Add position to vault
        if (positionIndex[tokenId] == 0) {
            totalPositions++;
            positionIds[totalPositions] = tokenId;
            positionIndex[tokenId] = totalPositions;
        }
        positionShares[tokenId] = shares;
        
        // Update total value
        totalValue += positionValue;
        
        // Mint vault tokens to user
        _mint(account, shares);
        
        // Approve Comet to spend the shares on behalf of the user
        // This allows Comet to pull tokens when supplyFrom is called
        if (allowance[account][cometAddress] < shares) {
            allowance[account][cometAddress] = type(uint256).max;
            emit Approval(account, cometAddress, type(uint256).max);
        }
        
        // Check if user has allowed Vault to act as manager in Comet
        // This is required for supplyFrom to work (hasPermission check in supplyInternal)
        IComet comet = IComet(cometAddress);
        bool vaultAllowed = comet.hasPermission(account, address(this));
        if (!vaultAllowed) {
            // User must call Comet.allow(vaultAddress, true) first
            revert("Vault must be allowed by user in Comet first. Call Comet.allow(vaultAddress, true)");
        }
        
        // Supply to Comet using supplyFrom
        // Vault acts as operator (msg.sender), transferring from account to account in Comet
        // hasPermission(account, Vault) must be true, which we checked above
        comet.supplyFrom(account, account, address(this), shares);
        
        emit Deposit(account, tokenId, shares, positionValue);
        
        return shares;
    }
    
    
    
    /**
     * @notice Withdraw from Comet and withdraw NFT in one transaction
     * @param tokenId The NFT token ID to withdraw
     * @param account The account to withdraw from Comet (usually msg.sender)
     * @dev This function combines withdraw from Comet and withdraw NFT in a single call
     *      Requires Comet to be set and the vault to be approved by the user
     *      First withdraws shares from Comet, then withdraws NFT from vault
     */
    function withdrawFromCometAndWithdrawNFT(uint256 tokenId, address account) external nonReentrant {
        require(cometAddress != address(0), "Comet address not set");
        require(account != address(0), "Invalid account");
        require(positionOwner[tokenId] == account, "Not the owner of this tokenId");
        require(positionIndex[tokenId] != 0, "Position not in vault");
        
        // Get shares for this tokenId
        uint256 shares = positionShares[tokenId];
        require(shares > 0, "No shares for this tokenId");
        
        // Check if user has shares in Comet (they should, if they used depositAndSupplyToComet)
        IComet comet = IComet(cometAddress);
        
        // Check if user has allowed Vault to act as manager in Comet
        // This is required for withdraw to work (hasPermission check in withdrawInternal)
        bool vaultAllowed = comet.hasPermission(account, address(this));
        if (!vaultAllowed) {
            revert("Vault must be allowed by user in Comet first. Call Comet.allow(vaultAddress, true)");
        }
        
        // Withdraw specific tokenId via Comet (vault acts as operator)
        comet.withdrawCollateralWithTokenId(account, account, address(this), tokenId);
        
        // Verify shares were burned from Comet and transferred back to user wallet
        require(balanceOf[account] >= shares, "Insufficient shares after Comet withdrawal");
        
        // Get current position value
        (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
        uint256 currentPositionValue = _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
        
        // Burn all shares
        _burn(account, shares);
        
        // Clean up position state
        positionShares[tokenId] = 0;
        address originalOwner = positionOwner[tokenId];
        delete positionOwner[tokenId];
        
        // Remove from user's tokenId list
        uint256 userIndex = positionIndexInUserArray[tokenId];
        uint256 userPositionsLength = userPositions[account].length;
        require(userPositionsLength > 0, "User positions array empty");
        
        uint256 lastUserTokenId = userPositions[account][userPositionsLength - 1];
        if (userIndex != userPositionsLength - 1) {
            userPositions[account][userIndex] = lastUserTokenId;
            positionIndexInUserArray[lastUserTokenId] = userIndex;
        }
        userPositions[account].pop();
        delete positionIndexInUserArray[tokenId];
        
        // Remove from global position list
        uint256 globalIndex = positionIndex[tokenId];
        uint256 lastGlobalTokenId = positionIds[totalPositions];
        if (globalIndex != totalPositions) {
            positionIds[globalIndex] = lastGlobalTokenId;
            positionIndex[lastGlobalTokenId] = globalIndex;
        }
        delete positionIds[totalPositions];
        delete positionIndex[tokenId];
        totalPositions--;
        
        // Update total value
        if (currentPositionValue > totalValue) {
            totalValue = 0; // Prevent underflow
        } else {
            totalValue -= currentPositionValue;
        }
        
        // Transfer NFT back to user
        IERC721(nftPositionManager).safeTransferFrom(address(this), account, tokenId);
        
        emit Withdraw(account, tokenId, shares);
    }
    
   
    
    /**
     * @notice Sync total value with current position values
     * @dev Updates totalValue by recalculating all positions
     */
    function sync() public {
        uint256 newTotalValue = 0;
        for (uint256 i = 1; i <= totalPositions; i++) {
            uint256 tokenId = positionIds[i];
            if (tokenId != 0) {
                (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
                newTotalValue += _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
            }
        }
        totalValue = newTotalValue;
        emit Sync(newTotalValue);
    }
    
    /**
     * @notice Get the total value of all positions in the vault
     * @return totalValue The total USD value of all positions (in 18 decimals)
     */
    function getTotalValue() external returns (uint256) {
        // Sync before returning
        sync();
        return totalValue;
    }
    
    /**
     * @notice Calculate the USD value of a position using Chainlink price feeds
     * @param realXY The real X and Y amounts in the position
     * @param priceSqrtX96 The sqrt price from oracle
     * @return value The USD value of the position (in 18 decimals)
     * @dev Note: Following impermax-v3-core's conservative approach, unclaimed fees are NOT included
     *      Only the base assets (realX, realY) are valued
     */
    function _calculatePositionValueUSD(INFTLP.RealXY memory realXY, uint256 priceSqrtX96) internal view returns (uint256 value) {
        // Get token prices from Chainlink
        (, int256 token0Price, , , ) = AggregatorV3Interface(token0PriceFeed).latestRoundData();
        (, int256 token1Price, , , ) = AggregatorV3Interface(token1PriceFeed).latestRoundData();
        
        require(token0Price > 0 && token1Price > 0, "Invalid prices");
        
        // Convert token0 amount to USD
        // realXY.realX is in token0's native decimals
        // token0Price is in 8 decimals (Chainlink standard)
        // Result should be in 18 decimals
        uint256 token0PriceScaled = uint256(token0Price) * 1e10; // 将 8 位精度扩展到 18 位
        uint256 token0Value = FullMath.mulDiv(realXY.realX, token0PriceScaled, 10 ** token0Decimals);
        
        // Convert token1 amount to USD
        // realXY.realY is in token1's native decimals
        // token1Price is in 8 decimals (Chainlink standard)
        // Result should be in 18 decimals
        uint256 token1PriceScaled = uint256(token1Price) * 1e10;
        uint256 token1Value = FullMath.mulDiv(realXY.realY, token1PriceScaled, 10 ** token1Decimals);
        
        value = token0Value + token1Value;
        
        priceSqrtX96; // Silence unused variable warning
    }
    
    /**
     * @notice Set Comet contract address (for allowing transfers to Compound V3)
     * @param _cometAddress The Comet contract address
     * @dev Only owner can set this
     */
    function setCometAddress(address _cometAddress) external onlyOwner {
        address oldCometAddress = cometAddress;
        cometAddress = _cometAddress;
        emit CometAddressUpdated(oldCometAddress, _cometAddress);
    }
    
    /**
     * @notice Get all tokenIds deposited by a user and their corresponding values
     * @param user The user address
     * @return positions Array of UserPosition structs, each containing tokenId and its USD value (in 18 decimals)
     */
    function getUserPositions(address user) external view returns (UserPosition[] memory positions) {
        uint256[] memory allTokenIds = userPositions[user];
        uint256 validCount = 0;
        
        // First pass: count valid positions
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tokenId = allTokenIds[i];
            if (positionOwner[tokenId] == user && positionIndex[tokenId] != 0) {
                validCount++;
            }
        }
        
        // Initialize array with valid count
        positions = new UserPosition[](validCount);
        
        // Second pass: populate array with valid positions and their values
        uint256 index = 0;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tokenId = allTokenIds[i];
            if (positionOwner[tokenId] == user && positionIndex[tokenId] != 0) {
                // Calculate position value
                (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
                uint256 value = _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
                
                positions[index] = UserPosition({
                    tokenId: tokenId,
                    value: value
                });
                index++;
            }
        }
    }
    
    /**
     * @notice Get the owner of a tokenId
     * @param tokenId The tokenId
     * @return The owner address (address(0) if not deposited)
     */
    function getPositionOwner(uint256 tokenId) external view returns (address) {
        return positionOwner[tokenId];
    }
    
    /**
     * @notice Get the total value of all positions owned by a user
     * @param user The user address
     * @return totalUserValue The total USD value of all user's positions (in 18 decimals)
     * @dev This provides accurate valuation for each user, solving the shares allocation issue
     */
    function getUserTotalValue(address user) external view returns (uint256 totalUserValue) {
        uint256[] memory tokenIds = userPositions[user];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (positionOwner[tokenId] == user && positionIndex[tokenId] != 0) {
                (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
                totalUserValue += _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
            }
        }
    }

    /**
     * @notice Get the total shares corresponding to all positions owned by a user
     * @param user The user address
     * @return totalShares Sum of shares for all tokenIds owned by the user (18 decimals)
     */
    function getUserTotalShares(address user) external view returns (uint256 totalShares) {
        uint256[] memory tokenIds = userPositions[user];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (positionOwner[tokenId] == user && positionIndex[tokenId] != 0) {
                totalShares += positionShares[tokenId];
            }
        }
    }
    
    /**
     * @notice Get the total underlying token0 and token1 amounts for all positions owned by a user
     * @param user The user address
     * @return token0Amount Total token0 amount across all user's positions (in token0's native decimals)
     * @return token1Amount Total token1 amount across all user's positions (in token1's native decimals)
     * @dev This sums the realX / realY from each position's currentPrice, without including unclaimed fees
     */
    function getUserTokenAmounts(address user) external view returns (uint256 token0Amount, uint256 token1Amount) {
        uint256[] memory tokenIds = userPositions[user];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            // Only count positions that are currently in the vault and owned by the user
            if (positionOwner[tokenId] == user && positionIndex[tokenId] != 0) {
                (, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
                // Sum currentPrice.realX / realY as underlying token amounts
                token0Amount += realXYs.currentPrice.realX;
                token1Amount += realXYs.currentPrice.realY;
            }
        }
    }
    
    /**
     * @notice ERC721 receiver function
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
    
    /*** Liquidation Functions ***/
    
    /**
     * @notice Check if this contract is a UniV3LPVault
     * @return true always
     */
    function isUniV3LPVault() external pure override returns (bool) {
        return true;
    }
    
    /**
     * @notice Get tokenIds that can be liquidated for a given account
     * @param account The account address
     * @return tokenIds Array of tokenIds owned by the account
     */
    function getLiquidatableTokenIds(address account) external view override returns (uint256[] memory tokenIds) {
        return userPositions[account];
    }
    
    /**
     * @notice Get the shares amount for a specific tokenId
     * @param tokenId The NFT tokenId
     * @return shares The shares amount for this tokenId
     */
    function getTokenIdShares(uint256 tokenId) external view override returns (uint256 shares) {
        return positionShares[tokenId];
    }
    
    /**
     * @notice Get the USD value (18 decimals) of a specific tokenId
     * @param tokenId The NFT tokenId
     * @return value The USD value in 18 decimals
     */
    function getTokenIdValue(uint256 tokenId) external view override returns (uint256 value) {
        if (positionOwner[tokenId] == address(0) || positionIndex[tokenId] == 0) {
            return 0;
        }
        (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
        value = _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
    }
    
    /**
     * @notice Liquidate: Transfer NFT directly to liquidator (bypassing shares)
     * @param tokenId The NFT tokenId to liquidate
     * @param liquidator The liquidator address
     * @dev Only callable by Comet contract
     * @dev Comet must hold sufficient shares for this tokenId
     * @dev This function burns the corresponding shares from Comet and transfers the NFT to liquidator
     */
    function liquidateTransferNFT(uint256 tokenId, address liquidator, bytes calldata paymentData) external override nonReentrant {
        require(msg.sender == cometAddress, "Only Comet can call");
        require(positionIndex[tokenId] != 0, "Position not in vault");
        
        // Get shares for this tokenId
        uint256 shares = positionShares[tokenId];
        require(shares > 0, "No shares for this tokenId");
        
        // Verify Comet holds sufficient shares
        require(balanceOf[msg.sender] >= shares, "Insufficient shares in Comet");
        
        // Burn shares from Comet
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        emit Transfer(msg.sender, address(0), shares);
        
        // Clean up position state
        positionShares[tokenId] = 0;
        address originalOwner = positionOwner[tokenId];
        delete positionOwner[tokenId];
        
        // Remove from user's tokenId list
        if (originalOwner != address(0)) {
            uint256 userIndex = positionIndexInUserArray[tokenId];
            uint256 userPositionsLength = userPositions[originalOwner].length;
            if (userPositionsLength > 0) {
                uint256 lastUserTokenId = userPositions[originalOwner][userPositionsLength - 1];
                if (userIndex != userPositionsLength - 1) {
                    userPositions[originalOwner][userIndex] = lastUserTokenId;
                    positionIndexInUserArray[lastUserTokenId] = userIndex;
                }
                userPositions[originalOwner].pop();
                delete positionIndexInUserArray[tokenId];
            }
        }
        
        // Remove from global position list
        uint256 globalIndex = positionIndex[tokenId];
        uint256 lastGlobalTokenId = positionIds[totalPositions];
        if (globalIndex != totalPositions) {
            positionIds[globalIndex] = lastGlobalTokenId;
            positionIndex[lastGlobalTokenId] = globalIndex;
        }
        delete positionIds[totalPositions];
        delete positionIndex[tokenId];
        totalPositions--;
        
        // Update total value
        (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs) = INFTLP(nftlp).getPositionData(tokenId, 1e18);
        uint256 currentPositionValue = _calculatePositionValueUSD(realXYs.currentPrice, priceSqrtX96);
        if (currentPositionValue > totalValue) {
            totalValue = 0; // Prevent underflow
        } else {
            totalValue -= currentPositionValue;
        }
        
        // Transfer NFT directly to liquidator
        // Note: We call nftPositionManager directly instead of through adapter
        // because we are the owner and need to transfer directly
        IERC721(nftPositionManager).safeTransferFrom(address(this), liquidator, tokenId, paymentData);
        
        emit LiquidateTransferNFT(liquidator, tokenId, shares);
    }
}

