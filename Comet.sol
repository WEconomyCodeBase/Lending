// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./CometMainInterface.sol";
import "./IERC20NonStandard.sol";
import "./IPriceFeed.sol";
import "./IUserPriceFeed.sol";
import "./univ3lp/interfaces/IUniV3LPVault.sol";

/**
 * @title Compound's Comet Contract
 * @notice An efficient monolithic money market protocol
 * @author Compound
 */
contract Comet is CometMainInterface {
    /** General configuration constants **/

    /// @notice The admin of the protocol
    address public override immutable governor;

    /// @notice The account which may trigger pauses
    address public override immutable pauseGuardian;

    /// @notice The address of the base token contract
    address public override immutable baseToken;

    /// @notice The address of the price feed for the base token
    address public override immutable baseTokenPriceFeed;

    /// @notice The address of the extension contract delegate
    address public override immutable extensionDelegate;

    /// @notice The point in the supply rates separating the low interest rate slope and the high interest rate slope (factor)
    /// @dev uint64
    uint public override immutable supplyKink;

    /// @notice Per second supply interest rate slope applied when utilization is below kink (factor)
    /// @dev uint64
    uint public override immutable supplyPerSecondInterestRateSlopeLow;

    /// @notice Per second supply interest rate slope applied when utilization is above kink (factor)
    /// @dev uint64
    uint public override immutable supplyPerSecondInterestRateSlopeHigh;

    /// @notice Per second supply base interest rate (factor)
    /// @dev uint64
    uint public override immutable supplyPerSecondInterestRateBase;

    /// @notice The point in the borrow rate separating the low interest rate slope and the high interest rate slope (factor)
    /// @dev uint64
    uint public override immutable borrowKink;

    /// @notice Per second borrow interest rate slope applied when utilization is below kink (factor)
    /// @dev uint64
    uint public override immutable borrowPerSecondInterestRateSlopeLow;

    /// @notice Per second borrow interest rate slope applied when utilization is above kink (factor)
    /// @dev uint64
    uint public override immutable borrowPerSecondInterestRateSlopeHigh;

    /// @notice Per second borrow base interest rate (factor)
    /// @dev uint64
    uint public override immutable borrowPerSecondInterestRateBase;

    /// @notice The fraction of the liquidation penalty that goes to buyers of collateral instead of the protocol
    /// @dev uint64
    uint public override immutable storeFrontPriceFactor;

    /// @notice The scale for base token (must be less than 18 decimals)
    /// @dev uint64
    uint public override immutable baseScale;

    /// @notice The scale for reward tracking
    /// @dev uint64
    uint public override immutable trackingIndexScale;

    /// @notice The speed at which supply rewards are tracked (in trackingIndexScale)
    /// @dev uint64
    uint public override immutable baseTrackingSupplySpeed;

    /// @notice The speed at which borrow rewards are tracked (in trackingIndexScale)
    /// @dev uint64
    uint public override immutable baseTrackingBorrowSpeed;

    /// @notice The minimum amount of base principal wei for rewards to accrue
    /// @dev This must be large enough so as to prevent division by base wei from overflowing the 64 bit indices
    /// @dev uint104
    uint public override immutable baseMinForRewards;

    /// @notice The minimum base amount required to initiate a borrow
    uint public override immutable baseBorrowMin;

    /// @notice The minimum base token reserves which must be held before collateral is hodled
    uint public override immutable targetReserves;

    /// @notice The number of decimals for wrapped base token
    uint8 public override immutable decimals;

    /// @notice The number of assets this contract actually supports
    uint8 public override immutable numAssets;

    /// @dev Single-call flag to skip duplicate collateral check when pre-checked (non-reentrant)
    bool private _skipCollateralCheck;

    /// @notice Factor to divide by when accruing rewards in order to preserve 6 decimals (i.e. baseScale / 1e6)
    uint internal immutable accrualDescaleFactor;

    /** Collateral asset configuration (packed) **/

    uint256 internal immutable asset00_a;
    uint256 internal immutable asset00_b;
    uint256 internal immutable asset01_a;
    uint256 internal immutable asset01_b;
    uint256 internal immutable asset02_a;
    uint256 internal immutable asset02_b;
    uint256 internal immutable asset03_a;
    uint256 internal immutable asset03_b;
    uint256 internal immutable asset04_a;
    uint256 internal immutable asset04_b;
    uint256 internal immutable asset05_a;
    uint256 internal immutable asset05_b;
    uint256 internal immutable asset06_a;
    uint256 internal immutable asset06_b;
    uint256 internal immutable asset07_a;
    uint256 internal immutable asset07_b;
    uint256 internal immutable asset08_a;
    uint256 internal immutable asset08_b;
    uint256 internal immutable asset09_a;
    uint256 internal immutable asset09_b;
    uint256 internal immutable asset10_a;
    uint256 internal immutable asset10_b;
    uint256 internal immutable asset11_a;
    uint256 internal immutable asset11_b;

    /**
     * @notice Construct a new protocol instance
     * @param config The mapping of initial/constant parameters
     **/
    constructor(Configuration memory config) {
        // Sanity checks
        uint8 decimals_ = IERC20NonStandard(config.baseToken).decimals();
        if (decimals_ > MAX_BASE_DECIMALS) revert BadDecimals();
        if (config.storeFrontPriceFactor > FACTOR_SCALE) revert BadDiscount();
        if (config.assetConfigs.length > MAX_ASSETS) revert TooManyAssets();
        if (config.baseMinForRewards == 0) revert BadMinimum();
        if (IPriceFeed(config.baseTokenPriceFeed).decimals() != PRICE_FEED_DECIMALS) revert BadDecimals();

        // Copy configuration
        unchecked {
            governor = config.governor;
            pauseGuardian = config.pauseGuardian;
            baseToken = config.baseToken;
            baseTokenPriceFeed = config.baseTokenPriceFeed;
            extensionDelegate = config.extensionDelegate;
            storeFrontPriceFactor = config.storeFrontPriceFactor;

            decimals = decimals_;
            baseScale = uint64(10 ** decimals_);
            trackingIndexScale = config.trackingIndexScale;
            if (baseScale < BASE_ACCRUAL_SCALE) revert BadDecimals();
            accrualDescaleFactor = baseScale / BASE_ACCRUAL_SCALE;

            baseMinForRewards = config.baseMinForRewards;
            baseTrackingSupplySpeed = config.baseTrackingSupplySpeed;
            baseTrackingBorrowSpeed = config.baseTrackingBorrowSpeed;

            baseBorrowMin = config.baseBorrowMin;
            targetReserves = config.targetReserves;
        }

        // Set interest rate model configs
        unchecked {
            supplyKink = config.supplyKink;
            supplyPerSecondInterestRateSlopeLow = config.supplyPerYearInterestRateSlopeLow / SECONDS_PER_YEAR;
            supplyPerSecondInterestRateSlopeHigh = config.supplyPerYearInterestRateSlopeHigh / SECONDS_PER_YEAR;
            supplyPerSecondInterestRateBase = config.supplyPerYearInterestRateBase / SECONDS_PER_YEAR;
            borrowKink = config.borrowKink;
            borrowPerSecondInterestRateSlopeLow = config.borrowPerYearInterestRateSlopeLow / SECONDS_PER_YEAR;
            borrowPerSecondInterestRateSlopeHigh = config.borrowPerYearInterestRateSlopeHigh / SECONDS_PER_YEAR;
            borrowPerSecondInterestRateBase = config.borrowPerYearInterestRateBase / SECONDS_PER_YEAR;
        }

        // Set asset info
        numAssets = uint8(config.assetConfigs.length);

        (asset00_a, asset00_b) = getPackedAssetInternal(config.assetConfigs, 0);
        (asset01_a, asset01_b) = getPackedAssetInternal(config.assetConfigs, 1);
        (asset02_a, asset02_b) = getPackedAssetInternal(config.assetConfigs, 2);
        (asset03_a, asset03_b) = getPackedAssetInternal(config.assetConfigs, 3);
        (asset04_a, asset04_b) = getPackedAssetInternal(config.assetConfigs, 4);
        (asset05_a, asset05_b) = getPackedAssetInternal(config.assetConfigs, 5);
        (asset06_a, asset06_b) = getPackedAssetInternal(config.assetConfigs, 6);
        (asset07_a, asset07_b) = getPackedAssetInternal(config.assetConfigs, 7);
        (asset08_a, asset08_b) = getPackedAssetInternal(config.assetConfigs, 8);
        (asset09_a, asset09_b) = getPackedAssetInternal(config.assetConfigs, 9);
        (asset10_a, asset10_b) = getPackedAssetInternal(config.assetConfigs, 10);
        (asset11_a, asset11_b) = getPackedAssetInternal(config.assetConfigs, 11);

        // Initialize allowed liquidators
        for (uint i = 0; i < config.initialAllowedLiquidators.length; i++) {
            address liquidator = config.initialAllowedLiquidators[i];
            if (liquidator != address(0)) {
                allowedLiquidators[liquidator] = true;
                emit SetAllowedLiquidator(liquidator, true);
            }
        }
    }

    /**
     * @dev Prevents marked functions from being reentered 
     * Note: this restrict contracts from calling comet functions in their hooks.
     * Doing so will cause the transaction to revert.
     */
    modifier nonReentrant() {
        nonReentrantBefore();
        _;
        nonReentrantAfter();
    }

    /**
     * @dev Checks that the reentrancy flag is not set and then sets the flag
     */
    function nonReentrantBefore() internal {
        bytes32 slot = REENTRANCY_GUARD_FLAG_SLOT;
        uint256 status;
        assembly ("memory-safe") {
            status := sload(slot)
        }

        if (status == REENTRANCY_GUARD_ENTERED) revert ReentrantCallBlocked();
        assembly ("memory-safe") {
            sstore(slot, REENTRANCY_GUARD_ENTERED)
        }
    }

    /**
     * @dev Unsets the reentrancy flag
     */
    function nonReentrantAfter() internal {
        bytes32 slot = REENTRANCY_GUARD_FLAG_SLOT;
        uint256 status;
        assembly ("memory-safe") {
            sstore(slot, REENTRANCY_GUARD_NOT_ENTERED)
        }
    }

    /**
     * @notice Initialize storage for the contract
     * @dev Can be used from constructor or proxy
     */
    function initializeStorage() override external {
        if (lastAccrualTime != 0) revert AlreadyInitialized();

        // Initialize aggregates
        lastAccrualTime = getNowInternal();
        baseSupplyIndex = BASE_INDEX_SCALE;
        baseBorrowIndex = BASE_INDEX_SCALE;

        // Implicit initialization (not worth increasing contract size)
        // trackingSupplyIndex = 0;
        // trackingBorrowIndex = 0;
    }

    /**
     * @dev Checks and gets the packed asset info for storage
     */
    function getPackedAssetInternal(AssetConfig[] memory assetConfigs, uint i) internal view returns (uint256, uint256) {
        AssetConfig memory assetConfig;
        if (i < assetConfigs.length) {
            assembly {
                assetConfig := mload(add(add(assetConfigs, 0x20), mul(i, 0x20)))
            }
        } else {
            return (0, 0);
        }
        address asset = assetConfig.asset;
        address priceFeed = assetConfig.priceFeed;
        uint8 decimals_ = assetConfig.decimals;

        // Short-circuit if asset is nil
        if (asset == address(0)) {
            return (0, 0);
        }

        // Sanity check price feed and asset decimals
        if (IPriceFeed(priceFeed).decimals() != PRICE_FEED_DECIMALS) revert BadDecimals();
        if (IERC20NonStandard(asset).decimals() != decimals_) revert BadDecimals();

        // Ensure collateral factors are within range
        if (assetConfig.borrowCollateralFactor >= assetConfig.liquidateCollateralFactor) revert BorrowCFTooLarge();
        if (assetConfig.liquidateCollateralFactor > MAX_COLLATERAL_FACTOR) revert LiquidateCFTooLarge();

        unchecked {
            // Keep 4 decimals for each factor
            uint64 descale = FACTOR_SCALE / 1e4;
            uint16 borrowCollateralFactor = uint16(assetConfig.borrowCollateralFactor / descale);
            uint16 liquidateCollateralFactor = uint16(assetConfig.liquidateCollateralFactor / descale);
            uint16 liquidationFactor = uint16(assetConfig.liquidationFactor / descale);

            // Be nice and check descaled values are still within range
            if (borrowCollateralFactor >= liquidateCollateralFactor) revert BorrowCFTooLarge();

            // Keep whole units of asset for supply cap
            uint64 supplyCap = uint64(assetConfig.supplyCap / (10 ** decimals_));

            uint256 word_a = (uint160(asset) << 0 |
                              uint256(borrowCollateralFactor) << 160 |
                              uint256(liquidateCollateralFactor) << 176 |
                              uint256(liquidationFactor) << 192);
            uint256 word_b = (uint160(priceFeed) << 0 |
                              uint256(decimals_) << 160 |
                              uint256(supplyCap) << 168);

            return (word_a, word_b);
        }
    }

    /**
     * @notice Get the i-th asset info, according to the order they were passed in originally
     * @param i The index of the asset info to get
     * @return The asset info object
     */
    function getAssetInfo(uint8 i) override public view returns (AssetInfo memory) {
        if (i >= numAssets) revert BadAsset();

        uint256 word_a;
        uint256 word_b;

        if (i == 0) {
            word_a = asset00_a;
            word_b = asset00_b;
        } else if (i == 1) {
            word_a = asset01_a;
            word_b = asset01_b;
        } else if (i == 2) {
            word_a = asset02_a;
            word_b = asset02_b;
        } else if (i == 3) {
            word_a = asset03_a;
            word_b = asset03_b;
        } else if (i == 4) {
            word_a = asset04_a;
            word_b = asset04_b;
        } else if (i == 5) {
            word_a = asset05_a;
            word_b = asset05_b;
        } else if (i == 6) {
            word_a = asset06_a;
            word_b = asset06_b;
        } else if (i == 7) {
            word_a = asset07_a;
            word_b = asset07_b;
        } else if (i == 8) {
            word_a = asset08_a;
            word_b = asset08_b;
        } else if (i == 9) {
            word_a = asset09_a;
            word_b = asset09_b;
        } else if (i == 10) {
            word_a = asset10_a;
            word_b = asset10_b;
        } else if (i == 11) {
            word_a = asset11_a;
            word_b = asset11_b;
        } else {
            revert Absurd();
        }

        address asset = address(uint160(word_a & type(uint160).max));
        uint64 rescale = FACTOR_SCALE / 1e4;
        uint64 borrowCollateralFactor = uint64(((word_a >> 160) & type(uint16).max) * rescale);
        uint64 liquidateCollateralFactor = uint64(((word_a >> 176) & type(uint16).max) * rescale);
        uint64 liquidationFactor = uint64(((word_a >> 192) & type(uint16).max) * rescale);

        address priceFeed = address(uint160(word_b & type(uint160).max));
        uint8 decimals_ = uint8(((word_b >> 160) & type(uint8).max));
        uint64 scale = uint64(10 ** decimals_);
        uint128 supplyCap = uint128(((word_b >> 168) & type(uint64).max) * scale);

        return AssetInfo({
            offset: i,
            asset: asset,
            priceFeed: priceFeed,
            scale: scale,
            borrowCollateralFactor: borrowCollateralFactor,
            liquidateCollateralFactor: liquidateCollateralFactor,
            liquidationFactor: liquidationFactor,
            supplyCap: supplyCap
         });
    }

    /**
     * @dev Determine index of asset that matches given address
     */
    function getAssetInfoByAddress(address asset) override public view returns (AssetInfo memory) {
        for (uint8 i = 0; i < numAssets; ) {
            AssetInfo memory assetInfo = getAssetInfo(i);
            if (assetInfo.asset == asset) {
                return assetInfo;
            }
            unchecked { i++; }
        }
        revert BadAsset();
    }

    /**
     * @notice Get all asset information for a user account with values
     * @param account The account address
     * @return An array of UserAssetInfo containing asset details, user balance, and value
     * @dev 返回规则（统一按各自价格预言机的单位返回价值）：
     *      - 所有资产都会返回完整的 AssetInfo 和用户抵押数量（balance，按 asset.scale 计数）
     *      - 对于 ERC20 抵押资产：
     *          value 字段为「该资产自身价格预言机表示的价值」，单位为 PRICE_FEED_DECIMALS（通常是 8 位 USD）
     *          计算公式：value = balance * price / asset.scale
     *      - 对于 UniV3LPVault 类型的 NFT 抵押资产：
     *          value 字段同样为价格预言机（如 UniV3LPVaultPriceFeedV3）的返回单位（通常是 8 位 USD）
     *          计算公式：value = balance * userSpecificPrice / asset.scale
     */
    function getUserAssetInfos(address account) override public view returns (UserAssetInfo[] memory) {
        UserAssetInfo[] memory userAssets = new UserAssetInfo[](numAssets);
        
        for (uint8 i = 0; i < numAssets; ) {
            AssetInfo memory assetInfo = getAssetInfo(i);
            uint128 balance = userCollateral[account][assetInfo.asset].balance;
            uint128 totalSupply = totalsCollateral[assetInfo.asset].totalSupplyAsset;
            uint256 value = 0;
            bool isNFT = isUniV3LPVaultAsset(assetInfo.asset);
            uint256 token0Amount = 0;
            uint256 token1Amount = 0;
            
            // Calculate value if balance > 0
            if (balance > 0) {
                if (!isNFT) {
                    // ERC20 抵押资产：返回按其价格预言机计价的价值（单位：PRICE_FEED_DECIMALS，例如 8 位 USD）
                    uint256 assetPrice = getPrice(assetInfo.priceFeed); // 价格预言机返回值
                    value = mulPrice(balance, assetPrice, assetInfo.scale);
                } else {
                    // UniV3LPVault NFT 抵押资产：使用用户指定价格预言机（latestRoundDataForUser）
                    // 返回单位同样为 PRICE_FEED_DECIMALS（例如 8 位 USD）
                    uint256 assetPriceUser = getPriceForUser(assetInfo.priceFeed, account);
                    value = mulPrice(balance, assetPriceUser, assetInfo.scale);
                    
                    // Get token0 and token1 amounts from UniV3LPVault
                    try IUniV3LPVault(assetInfo.asset).getUserTokenAmounts(account) returns (
                        uint256 _token0Amount,
                        uint256 _token1Amount
                    ) {
                        token0Amount = _token0Amount;
                        token1Amount = _token1Amount;
                    } catch {
                        // If getUserTokenAmounts fails, leave token0Amount and token1Amount as 0
                        // This handles cases where the vault doesn't support this function or has errors
                    }
                }
            }
            
            userAssets[i] = UserAssetInfo({
                assetInfo: assetInfo,
                balance: balance,
                totalSupply: totalSupply,
                value: value,
                isNFT: isNFT,
                token0Amount: token0Amount,
                token1Amount: token1Amount
            });
            
            unchecked { i++; }
        }
        
        return userAssets;
    }

    /**
     * @notice Get the total collateral value for an account in base token terms
     * @param account The account address
     * @return The total amount of base token equivalent for all collateral assets (same unit as borrowBalanceOf)
     * @dev This function calculates the total value of all user's collateral assets
     *      using user-specific prices for NFTs and standard prices for ERC20 tokens.
     *      Returns the equivalent amount of base token (in wei), consistent with borrowBalanceOf.
     *      Both functions return base token amounts in wei units, allowing direct comparison.
     */
    function getTotalCollateralValue(address account) override public view returns (uint) {
        uint16 assetsIn = userBasic[account].assetsIn;
        uint256 totalValue = 0;
        uint256 basePrice = getPrice(baseTokenPriceFeed);

        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                AssetInfo memory asset = getAssetInfo(i);
                uint128 balance = userCollateral[account][asset.asset].balance;
                
                if (balance > 0) {
                    // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
                    uint256 assetPrice = isUniV3LPVaultAsset(asset.asset)
                        ? getPriceForUser(asset.priceFeed, account)
                        : getPrice(asset.priceFeed);
                    
                    // Calculate equivalent base token amount using the same formula as collateralToBase
                    // This ensures consistency with borrowBalanceOf (both return base token amounts in wei)
                    // Formula: balance * assetPrice * baseScale / (basePrice * asset.scale)
                    uint256 baseValue = balance * assetPrice * baseScale / (basePrice * asset.scale);
                    totalValue += baseValue;
                }
            }
            unchecked { i++; }
        }

        return totalValue;
    }

    /**
     * @notice Get the value of a specific asset for a user account in base token terms
     * @param account The account address
     * @param asset The asset address (can be base token or collateral asset)
     * @return value The asset value in base token wei units (same unit as borrowBalanceOf)
     * @dev For base token: returns the supply balance directly (already in base token wei)
     *      For collateral assets: returns the equivalent base token amount
     */
    function getUserAssetValue(address account, address asset) override public view returns (uint256 value) {
        // If asset is base token, return supply balance directly (already in base token wei)
        if (asset == baseToken) {
            value = balanceOf(account);
        } else {
            // For collateral assets, calculate equivalent base token amount
            AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
            uint128 balance = userCollateral[account][asset].balance;
            
            if (balance > 0) {
                // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
                uint256 assetPrice = isUniV3LPVaultAsset(asset)
                    ? getPriceForUser(assetInfo.priceFeed, account)
                    : getPrice(assetInfo.priceFeed);
                uint256 basePrice = getPrice(baseTokenPriceFeed);
                
                // Calculate equivalent base token amount using the same formula as collateralToBase
                // This ensures consistency with borrowBalanceOf (both return base token amounts in wei)
                // Formula: balance * assetPrice * baseScale / (basePrice * asset.scale)
                value = balance * assetPrice * baseScale / (basePrice * assetInfo.scale);
            } else {
                value = 0;
            }
        }
    }

    /**
     * @notice Get the maximum borrowable amount for a user account
     * @param account The account address
     * @return availableBorrow Available borrow amount in base token wei units
     * @dev Returns 0 if user has no collateral or is already over-borrowed
     *      This is the amount the user can borrow before becoming undercollateralized
     */
    function getAvailableBorrow(address account) override public view returns (uint256 availableBorrow) {
        int104 principal = userBasic[account].principal;
        uint16 assetsIn = userBasic[account].assetsIn;
        
        // Get updated interest indices (like borrowBalanceOf does)
        (uint64 baseSupplyIndex_, uint64 baseBorrowIndex_) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        
        // Calculate current borrow value in USD (negative if borrowing)
        // Use updated indices to get present value with accrued interest
        int256 presentValue_;
        if (principal >= 0) {
            presentValue_ = signed256(presentValueSupply(baseSupplyIndex_, uint104(principal)));
        } else {
            presentValue_ = -signed256(presentValueBorrow(baseBorrowIndex_, uint104(-principal)));
        }
        
        int liquidity = signedMulPrice(
            presentValue_,
            getPrice(baseTokenPriceFeed),
            uint64(baseScale)
        );
        
        // If principal >= 0, user has supply or no borrow, so liquidity starts at 0 or positive
        // If principal < 0, user is borrowing, so liquidity is negative (current borrow value)
        
        // Accumulate borrowable value from all collateral assets
        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                AssetInfo memory asset = getAssetInfo(i);
                uint128 balance = userCollateral[account][asset.asset].balance;
                
                if (balance > 0) {
                    // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
                    uint256 assetPrice = isUniV3LPVaultAsset(asset.asset)
                        ? getPriceForUser(asset.priceFeed, account)
                        : getPrice(asset.priceFeed);
                    
                    // Calculate collateral USD value
                    uint256 collateralValue = mulPrice(balance, assetPrice, asset.scale);
                    
                    // Apply borrowCollateralFactor to get borrowable value
                    uint256 borrowableValue = mulFactor(collateralValue, asset.borrowCollateralFactor);
                    
                    // Add to liquidity (convert to int for addition)
                    liquidity += signed256(borrowableValue);
                }
            }
            unchecked { i++; }
        }
        
        // If liquidity <= 0, user cannot borrow more (already at or over limit)
        if (liquidity <= 0) {
            return 0;
        }
        
        // Convert liquidity (USD value) to base token amount
        // liquidity is in USD (18 decimals), convert to base token wei
        uint256 basePrice = getPrice(baseTokenPriceFeed);
        availableBorrow = uint256(liquidity) * baseScale / basePrice;
    }

    /**
     * @return The current timestamp
     **/
    function getNowInternal() virtual internal view returns (uint40) {
        if (block.timestamp >= 2**40) revert TimestampTooLarge();
        return uint40(block.timestamp);
    }

    /**
     * @dev Calculate accrued interest indices for base token supply and borrows
     **/
    function accruedInterestIndices(uint timeElapsed) internal view returns (uint64, uint64) {
        uint64 baseSupplyIndex_ = baseSupplyIndex;
        uint64 baseBorrowIndex_ = baseBorrowIndex;
        if (timeElapsed > 0) {
            uint utilization = getUtilization();
            uint supplyRate = getSupplyRate(utilization);
            uint borrowRate = getBorrowRate(utilization);
            baseSupplyIndex_ += safe64(mulFactor(baseSupplyIndex_, supplyRate * timeElapsed));
            baseBorrowIndex_ += safe64(mulFactor(baseBorrowIndex_, borrowRate * timeElapsed));
        }
        return (baseSupplyIndex_, baseBorrowIndex_);
    }

    /**
     * @dev Accrue interest (and rewards) in base token supply and borrows
     **/
    function accrueInternal() internal {
        uint40 now_ = getNowInternal();
        uint timeElapsed = uint256(now_ - lastAccrualTime);
        if (timeElapsed > 0) {
            (baseSupplyIndex, baseBorrowIndex) = accruedInterestIndices(timeElapsed);
            if (totalSupplyBase >= baseMinForRewards) {
                trackingSupplyIndex += safe64(divBaseWei(baseTrackingSupplySpeed * timeElapsed, totalSupplyBase));
            }
            if (totalBorrowBase >= baseMinForRewards) {
                trackingBorrowIndex += safe64(divBaseWei(baseTrackingBorrowSpeed * timeElapsed, totalBorrowBase));
            }
            lastAccrualTime = now_;
        }
    }

    /**
     * @notice Accrue interest and rewards for an account
     **/
    function accrueAccount(address account) override external {
        accrueInternal();

        UserBasic memory basic = userBasic[account];
        updateBasePrincipal(account, basic, basic.principal);
    }

    /**
     * @dev Note: Does not accrue interest first
     * @param utilization The utilization to check the supply rate for
     * @return The per second supply rate at `utilization`
     */
    function getSupplyRate(uint utilization) override public view returns (uint64) {
        if (utilization <= supplyKink) {
            // interestRateBase + interestRateSlopeLow * utilization
            return safe64(supplyPerSecondInterestRateBase + mulFactor(supplyPerSecondInterestRateSlopeLow, utilization));
        } else {
            // interestRateBase + interestRateSlopeLow * kink + interestRateSlopeHigh * (utilization - kink)
            return safe64(supplyPerSecondInterestRateBase + mulFactor(supplyPerSecondInterestRateSlopeLow, supplyKink) + mulFactor(supplyPerSecondInterestRateSlopeHigh, (utilization - supplyKink)));
        }
    }

    /**
     * @dev Note: Does not accrue interest first
     * @param utilization The utilization to check the borrow rate for
     * @return The per second borrow rate at `utilization`
     */
    function getBorrowRate(uint utilization) override public view returns (uint64) {
        if (utilization <= borrowKink) {
            // interestRateBase + interestRateSlopeLow * utilization
            return safe64(borrowPerSecondInterestRateBase + mulFactor(borrowPerSecondInterestRateSlopeLow, utilization));
        } else {
            // interestRateBase + interestRateSlopeLow * kink + interestRateSlopeHigh * (utilization - kink)
            return safe64(borrowPerSecondInterestRateBase + mulFactor(borrowPerSecondInterestRateSlopeLow, borrowKink) + mulFactor(borrowPerSecondInterestRateSlopeHigh, (utilization - borrowKink)));
        }
    }

    /**
     * @dev Note: Does not accrue interest first
     * @return The utilization rate of the base asset
     */
    function getUtilization() override public view returns (uint) {
        uint totalSupply_ = presentValueSupply(baseSupplyIndex, totalSupplyBase);
        uint totalBorrow_ = presentValueBorrow(baseBorrowIndex, totalBorrowBase);
        if (totalSupply_ == 0) {
            return 0;
        } else {
            return totalBorrow_ * FACTOR_SCALE / totalSupply_;
        }
    }

    /**
     * @notice Get the current price from a feed
     * @param priceFeed The address of a price feed
     * @return The price, scaled by `PRICE_SCALE`
     */
    function getPrice(address priceFeed) override public view returns (uint256) {
        (, int price, , , ) = IPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert BadPrice();
        return uint256(price);
    }
    
    /**
     * @notice Get the current price from a feed for a specific user
     * @param priceFeed The address of a price feed
     * @param user The user address (for user-specific price feeds)
     * @return The price, scaled by `PRICE_SCALE`
     * @dev If the price feed supports latestRoundDataForUser, use it; otherwise fall back to latestRoundData
     */
    function getPriceForUser(address priceFeed, address user) internal view returns (uint256) {
        // Try to use user-specific price feed if available
        // Check if price feed version is 3 (UniV3LPVaultPriceFeedV3)
        try IUserPriceFeed(priceFeed).version() returns (uint256 version) {
            if (version >= 3) {
                // Try to get user-specific price
                try IUserPriceFeed(priceFeed).latestRoundDataForUser(user) returns (
                    uint80,
                    int256 price,
                    uint256,
                    uint256,
                    uint80
                ) {
                    if (price > 0) {
                        return uint256(price);
                    }
                } catch {
                    // Fall through to standard price feed
                }
            }
        } catch {
            // Fall through to standard price feed
        }
        
        // Fall back to standard price feed
        (, int price, , , ) = IPriceFeed(priceFeed).latestRoundData();
        if (price <= 0) revert BadPrice();
        return uint256(price);
    }

    /**
     * @dev Check if an asset is a UniV3LPVault
     * @param asset The asset address to check
     * @return true if the asset is a UniV3LPVault
     */
    function isUniV3LPVaultAsset(address asset) internal view returns (bool) {
        try IUniV3LPVault(asset).isUniV3LPVault() returns (bool isVault) {
            return isVault;
        } catch {
            return false;
        }
    }

    /**
     * @notice Gets the total balance of protocol collateral reserves for an asset
     * @dev Note: Reverts if collateral reserves are somehow negative, which should not be possible
     * @param asset The collateral asset
     */
    function getCollateralReserves(address asset) override public view returns (uint) {
        return IERC20NonStandard(asset).balanceOf(address(this)) - totalsCollateral[asset].totalSupplyAsset;
    }

    /**
     * @notice Gets the total amount of protocol reserves of the base asset
     */
    function getReserves() override public view returns (int) {
        (uint64 baseSupplyIndex_, uint64 baseBorrowIndex_) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        uint balance = IERC20NonStandard(baseToken).balanceOf(address(this));
        uint totalSupply_ = presentValueSupply(baseSupplyIndex_, totalSupplyBase);
        uint totalBorrow_ = presentValueBorrow(baseBorrowIndex_, totalBorrowBase);
        return signed256(balance) - signed256(totalSupply_) + signed256(totalBorrow_);
    }

    /**
     * @notice Check whether an account has enough collateral to borrow
     * @param account The address to check
     * @return Whether the account is minimally collateralized enough to borrow
     */
    function isBorrowCollateralized(address account) override public view returns (bool) {
        int104 principal = userBasic[account].principal;

        if (principal >= 0) {
            return true;
        }

        uint16 assetsIn = userBasic[account].assetsIn;
        int liquidity = signedMulPrice(
            presentValue(principal),
            getPrice(baseTokenPriceFeed),
            uint64(baseScale)
        );

        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                if (liquidity >= 0) {
                    return true;
                }

                AssetInfo memory asset = getAssetInfo(i);
                uint128 balanceToUse = userCollateral[account][asset.asset].balance;
                
                uint256 assetPrice = isUniV3LPVaultAsset(asset.asset)
                    ? getPriceForUser(asset.priceFeed, account) // uses total shares (wallet + Comet) via price feed v3
                    : getPrice(asset.priceFeed);
                
                uint newAmount = mulPrice(
                    balanceToUse,
                    assetPrice,
                    asset.scale
                );
                liquidity += signed256(mulFactor(
                    newAmount,
                    asset.borrowCollateralFactor
                ));
            }
            unchecked { i++; }
        }

        return liquidity >= 0;
    }

    /**
     * @notice Check whether an account has enough collateral to not be liquidated
     * @param account The address to check
     * @return Whether the account is minimally collateralized enough to not be liquidated
     */
    function isLiquidatable(address account) override public returns (bool) {
        int104 principal = userBasic[account].principal;

        if (principal >= 0) {
            return false;
        }

        uint16 assetsIn = userBasic[account].assetsIn;
        int liquidity = signedMulPrice(
            presentValue(principal),
            getPrice(baseTokenPriceFeed),
            uint64(baseScale)
        );

        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                if (liquidity >= 0) {
                    return false;
                }

                AssetInfo memory asset = getAssetInfo(i);
                // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
                uint256 assetPrice = isUniV3LPVaultAsset(asset.asset)
                    ? getPriceForUser(asset.priceFeed, account)
                    : getPrice(asset.priceFeed);
                uint newAmount = mulPrice(
                    userCollateral[account][asset.asset].balance,
                    assetPrice,
                    asset.scale
                );
                liquidity += signed256(mulFactor(
                    newAmount,
                    asset.liquidateCollateralFactor
                ));
            }
            unchecked { i++; }
        }

        return liquidity < 0;
    }

    /**
     * @dev The change in principal broken into repay and supply amounts
     */
    function repayAndSupplyAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // If the new principal is less than the old principal, then no amount has been repaid or supplied
        if (newPrincipal < oldPrincipal) return (0, 0);

        if (newPrincipal <= 0) {
            return (uint104(newPrincipal - oldPrincipal), 0);
        } else if (oldPrincipal >= 0) {
            return (0, uint104(newPrincipal - oldPrincipal));
        } else {
            return (uint104(-oldPrincipal), uint104(newPrincipal));
        }
    }

    /**
     * @dev The change in principal broken into withdraw and borrow amounts
     */
    function withdrawAndBorrowAmount(int104 oldPrincipal, int104 newPrincipal) internal pure returns (uint104, uint104) {
        // If the new principal is greater than the old principal, then no amount has been withdrawn or borrowed
        if (newPrincipal > oldPrincipal) return (0, 0);

        if (newPrincipal >= 0) {
            return (uint104(oldPrincipal - newPrincipal), 0);
        } else if (oldPrincipal <= 0) {
            return (0, uint104(oldPrincipal - newPrincipal));
        } else {
            return (uint104(oldPrincipal), uint104(-newPrincipal));
        }
    }

    /**
     * @notice Pauses different actions within Comet
     * @param supplyPaused Boolean for pausing supply actions
     * @param transferPaused Boolean for pausing transfer actions
     * @param withdrawPaused Boolean for pausing withdraw actions
     * @param absorbPaused Boolean for pausing absorb actions
     * @param buyPaused Boolean for pausing buy actions
     */
    function pause(
        bool supplyPaused,
        bool transferPaused,
        bool withdrawPaused,
        bool absorbPaused,
        bool buyPaused
    ) override external {
        if (msg.sender != governor && msg.sender != pauseGuardian) revert Unauthorized();

        pauseFlags =
            uint8(0) |
            (toUInt8(supplyPaused) << PAUSE_SUPPLY_OFFSET) |
            (toUInt8(transferPaused) << PAUSE_TRANSFER_OFFSET) |
            (toUInt8(withdrawPaused) << PAUSE_WITHDRAW_OFFSET) |
            (toUInt8(absorbPaused) << PAUSE_ABSORB_OFFSET) |
            (toUInt8(buyPaused) << PAUSE_BUY_OFFSET);

        emit PauseAction(supplyPaused, transferPaused, withdrawPaused, absorbPaused, buyPaused);
    }

    /**
     * @return Whether or not supply actions are paused
     */
    function isSupplyPaused() override public view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_SUPPLY_OFFSET));
    }

    /**
     * @return Whether or not transfer actions are paused
     */
    function isTransferPaused() override public view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_TRANSFER_OFFSET));
    }

    /**
     * @return Whether or not withdraw actions are paused
     */
    function isWithdrawPaused() override public view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_WITHDRAW_OFFSET));
    }

    /**
     * @return Whether or not absorb actions are paused
     */
    function isAbsorbPaused() override public view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_ABSORB_OFFSET));
    }

    /**
     * @return Whether or not buy actions are paused
     */
    function isBuyPaused() override public view returns (bool) {
        return toBool(pauseFlags & (uint8(1) << PAUSE_BUY_OFFSET));
    }

    /**
     * @dev Multiply a number by a factor
     */
    function mulFactor(uint n, uint factor) internal pure returns (uint) {
        return n * factor / FACTOR_SCALE;
    }

    /**
     * @dev Divide a number by an amount of base
     */
    function divBaseWei(uint n, uint baseWei) internal view returns (uint) {
        return n * baseScale / baseWei;
    }

    /**
     * @dev Multiply a `fromScale` quantity by a price, returning a common price quantity
     */
    function mulPrice(uint n, uint price, uint64 fromScale) internal pure returns (uint) {
        return n * price / fromScale;
    }

    /**
     * @dev Multiply a signed `fromScale` quantity by a price, returning a common price quantity
     */
    function signedMulPrice(int n, uint price, uint64 fromScale) internal pure returns (int) {
        return n * signed256(price) / int256(uint256(fromScale));
    }

    /**
     * @dev Divide a common price quantity by a price, returning a `toScale` quantity
     */
    function divPrice(uint n, uint price, uint64 toScale) internal pure returns (uint) {
        return n * toScale / price;
    }

    /**
     * @dev Whether user has a non-zero balance of an asset, given assetsIn flags
     */
    function isInAsset(uint16 assetsIn, uint8 assetOffset) internal pure returns (bool) {
        return (assetsIn & (uint16(1) << assetOffset) != 0);
    }

    /**
     * @dev Update assetsIn bit vector if user has entered or exited an asset
     */
    function updateAssetsIn(
        address account,
        AssetInfo memory assetInfo,
        uint128 initialUserBalance,
        uint128 finalUserBalance
    ) internal {
        if (initialUserBalance == 0 && finalUserBalance != 0) {
            // set bit for asset
            userBasic[account].assetsIn |= (uint16(1) << assetInfo.offset);
        } else if (initialUserBalance != 0 && finalUserBalance == 0) {
            // clear bit for asset
            userBasic[account].assetsIn &= ~(uint16(1) << assetInfo.offset);
        }
    }

    /**
     * @dev Write updated principal to store and tracking participation
     */
    function updateBasePrincipal(address account, UserBasic memory basic, int104 principalNew) internal {
        int104 principal = basic.principal;
        basic.principal = principalNew;

        uint256 indexDelta = uint256(
            principal >= 0
                ? trackingSupplyIndex - basic.baseTrackingIndex
                : trackingBorrowIndex - basic.baseTrackingIndex
        );

        uint256 accruedDelta = uint256(
            (principal >= 0 ? uint104(principal) : uint104(-principal))
        ) * indexDelta / trackingIndexScale / accrualDescaleFactor;

        basic.baseTrackingAccrued += safe64(accruedDelta);

        if (principalNew >= 0) {
            basic.baseTrackingIndex = trackingSupplyIndex;
        } else {
            basic.baseTrackingIndex = trackingBorrowIndex;
        }

        userBasic[account] = basic;
    }

    /**
     * @dev Safe ERC20 transfer in and returns the final amount transferred (taking into account any fees)
     * @dev Note: Safely handles non-standard ERC-20 tokens that do not return a value. See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(address asset, address from, uint amount) internal returns (uint) {
        uint256 preTransferBalance = IERC20NonStandard(asset).balanceOf(address(this));
        IERC20NonStandard(asset).transferFrom(from, address(this), amount);
        bool success;
        assembly ("memory-safe") {
            switch returndatasize()
                case 0 {                       // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                      // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of override external call
                }
                default {                      // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }
        if (!success) revert TransferInFailed();
        return IERC20NonStandard(asset).balanceOf(address(this)) - preTransferBalance;
    }

    /**
     * @dev Safe ERC20 transfer out
     * @dev Note: Safely handles non-standard ERC-20 tokens that do not return a value. See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(address asset, address to, uint amount) internal {
        IERC20NonStandard(asset).transfer(to, amount);
        bool success;
        assembly ("memory-safe") {
            switch returndatasize()
                case 0 {                       // This is a non-standard ERC-20
                    success := not(0)          // set success to true
                }
                case 32 {                      // This is a compliant ERC-20
                    returndatacopy(0, 0, 32)
                    success := mload(0)        // Set `success = returndata` of override external call
                }
                default {                      // This is an excessively non-compliant ERC-20, revert.
                    revert(0, 0)
                }
        }
        if (!success) revert TransferOutFailed();
    }

    /**
     * @notice Supply an amount of asset to the protocol
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supply(address asset, uint amount) override external {
        return supplyInternal(msg.sender, msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice Supply an amount of asset to dst
     * @param dst The address which will hold the balance
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supplyTo(address dst, address asset, uint amount) override external {
        return supplyInternal(msg.sender, msg.sender, dst, asset, amount);
    }

    /**
     * @notice Supply an amount of asset from `from` to dst, if allowed
     * @param from The supplier address
     * @param dst The address which will hold the balance
     * @param asset The asset to supply
     * @param amount The quantity to supply
     */
    function supplyFrom(address from, address dst, address asset, uint amount) override external {
        return supplyInternal(msg.sender, from, dst, asset, amount);
    }

    /**
     * @dev Supply either collateral or base asset, depending on the asset, if operator is allowed
     * @dev Note: Specifying an `amount` of uint256.max will repay all of `dst`'s accrued base borrow balance
     */
    function supplyInternal(address operator, address from, address dst, address asset, uint amount) internal nonReentrant {
        if (isSupplyPaused()) revert Paused();
        if (!hasPermission(from, operator)) revert Unauthorized();

        if (asset == baseToken) {
            if (amount == type(uint256).max) {
                amount = borrowBalanceOf(dst);
            }
            return supplyBase(from, dst, amount);
        } else {
            return supplyCollateral(from, dst, asset, safe128(amount));
        }
    }

    /**
     * @dev Supply an amount of base asset from `from` to dst
     */
    function supplyBase(address from, address dst, uint256 amount) internal {
        amount = doTransferIn(baseToken, from, amount);

        accrueInternal();

        UserBasic memory dstUser = userBasic[dst];
        int104 dstPrincipal = dstUser.principal;
        int256 dstBalance = presentValue(dstPrincipal) + signed256(amount);
        int104 dstPrincipalNew = principalValue(dstBalance);

        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstPrincipal, dstPrincipalNew);

        totalSupplyBase += supplyAmount;
        totalBorrowBase -= repayAmount;

        // Update cumulative net principal for interest calculation
        if (supplyAmount > 0) {
            totalNetSupplyPrincipal[dst] += supplyAmount;
        }
        if (repayAmount > 0) {
            if (totalNetBorrowPrincipal[dst] >= repayAmount) {
                totalNetBorrowPrincipal[dst] -= repayAmount;
            } else {
                totalNetBorrowPrincipal[dst] = 0;
            }
        }

        updateBasePrincipal(dst, dstUser, dstPrincipalNew);

        emit Supply(from, dst, amount);

        if (supplyAmount > 0) {
            emit Transfer(address(0), dst, presentValueSupply(baseSupplyIndex, supplyAmount));
        }
    }

    /**
     * @dev Supply an amount of collateral asset from `from` to dst
     */
    function supplyCollateral(address from, address dst, address asset, uint128 amount) internal {
        amount = safe128(doTransferIn(asset, from, amount));

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        TotalsCollateral memory totals = totalsCollateral[asset];
        totals.totalSupplyAsset += amount;
        if (totals.totalSupplyAsset > assetInfo.supplyCap) revert SupplyCapExceeded();

        uint128 dstCollateral = userCollateral[dst][asset].balance;
        uint128 dstCollateralNew = dstCollateral + amount;

        totalsCollateral[asset] = totals;
        userCollateral[dst][asset].balance = dstCollateralNew;

        updateAssetsIn(dst, assetInfo, dstCollateral, dstCollateralNew);

        emit SupplyCollateral(from, dst, asset, amount);
    }

    /**
     * @notice ERC20 transfer an amount of base token to dst
     * @param dst The recipient address
     * @param amount The quantity to transfer
     * @return true
     */
    function transfer(address dst, uint amount) override external returns (bool) {
        transferInternal(msg.sender, msg.sender, dst, baseToken, amount);
        return true;
    }

    /**
     * @notice ERC20 transfer an amount of base token from src to dst, if allowed
     * @param src The sender address
     * @param dst The recipient address
     * @param amount The quantity to transfer
     * @return true
     */
    function transferFrom(address src, address dst, uint amount) override external returns (bool) {
        transferInternal(msg.sender, src, dst, baseToken, amount);
        return true;
    }

    /**
     * @notice Transfer an amount of asset to dst
     * @param dst The recipient address
     * @param asset The asset to transfer
     * @param amount The quantity to transfer
     */
    function transferAsset(address dst, address asset, uint amount) override external {
        return transferInternal(msg.sender, msg.sender, dst, asset, amount);
    }

    /**
     * @notice Transfer an amount of asset from src to dst, if allowed
     * @param src The sender address
     * @param dst The recipient address
     * @param asset The asset to transfer
     * @param amount The quantity to transfer
     */
    function transferAssetFrom(address src, address dst, address asset, uint amount) override external {
        return transferInternal(msg.sender, src, dst, asset, amount);
    }

    /**
     * @dev Transfer either collateral or base asset, depending on the asset, if operator is allowed
     * @dev Note: Specifying an `amount` of uint256.max will transfer all of `src`'s accrued base balance
     */
    function transferInternal(address operator, address src, address dst, address asset, uint amount) internal nonReentrant {
        if (isTransferPaused()) revert Paused();
        if (!hasPermission(src, operator)) revert Unauthorized();
        if (src == dst) revert NoSelfTransfer();

        if (asset == baseToken) {
            if (amount == type(uint256).max) {
                amount = balanceOf(src);
            }
            return transferBase(src, dst, amount);
        } else {
            return transferCollateral(src, dst, asset, safe128(amount));
        }
    }

    /**
     * @dev Transfer an amount of base asset from src to dst, borrowing if possible/necessary
     */
    function transferBase(address src, address dst, uint256 amount) internal {
        accrueInternal();

        UserBasic memory srcUser = userBasic[src];
        UserBasic memory dstUser = userBasic[dst];

        int104 srcPrincipal = srcUser.principal;
        int104 dstPrincipal = dstUser.principal;
        int256 srcBalance = presentValue(srcPrincipal) - signed256(amount);
        int256 dstBalance = presentValue(dstPrincipal) + signed256(amount);
        int104 srcPrincipalNew = principalValue(srcBalance);
        int104 dstPrincipalNew = principalValue(dstBalance);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcPrincipal, srcPrincipalNew);
        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(dstPrincipal, dstPrincipalNew);

        // Note: Instead of `total += addAmount - subAmount` to avoid underflow errors.
        totalSupplyBase = totalSupplyBase + supplyAmount - withdrawAmount;
        totalBorrowBase = totalBorrowBase + borrowAmount - repayAmount;

        // Update cumulative net principal for interest calculation
        if (withdrawAmount > 0) {
            if (totalNetSupplyPrincipal[src] >= withdrawAmount) {
                totalNetSupplyPrincipal[src] -= withdrawAmount;
            } else {
                totalNetSupplyPrincipal[src] = 0;
            }
        }
        if (borrowAmount > 0) {
            totalNetBorrowPrincipal[src] += borrowAmount;
        }
        if (supplyAmount > 0) {
            totalNetSupplyPrincipal[dst] += supplyAmount;
        }
        if (repayAmount > 0) {
            if (totalNetBorrowPrincipal[dst] >= repayAmount) {
                totalNetBorrowPrincipal[dst] -= repayAmount;
            } else {
                totalNetBorrowPrincipal[dst] = 0;
            }
        }

        updateBasePrincipal(src, srcUser, srcPrincipalNew);
        updateBasePrincipal(dst, dstUser, dstPrincipalNew);

        if (srcBalance < 0) {
            if (uint256(-srcBalance) < baseBorrowMin) revert BorrowTooSmall();
            if (!isBorrowCollateralized(src)) revert NotCollateralized();
        }

        if (withdrawAmount > 0) {
            emit Transfer(src, address(0), presentValueSupply(baseSupplyIndex, withdrawAmount));
        }

        if (supplyAmount > 0) {
            emit Transfer(address(0), dst, presentValueSupply(baseSupplyIndex, supplyAmount));
        }
    }

    /**
     * @dev Transfer an amount of collateral asset from src to dst
     */
    function transferCollateral(address src, address dst, address asset, uint128 amount) internal {
        uint128 srcCollateral = userCollateral[src][asset].balance;
        uint128 dstCollateral = userCollateral[dst][asset].balance;
        uint128 srcCollateralNew = srcCollateral - amount;
        uint128 dstCollateralNew = dstCollateral + amount;

        userCollateral[src][asset].balance = srcCollateralNew;
        userCollateral[dst][asset].balance = dstCollateralNew;

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        updateAssetsIn(src, assetInfo, srcCollateral, srcCollateralNew);
        updateAssetsIn(dst, assetInfo, dstCollateral, dstCollateralNew);

        // Note: no accrue interest, BorrowCF < LiquidationCF covers small changes
        if (!isBorrowCollateralized(src)) revert NotCollateralized();

        emit TransferCollateral(src, dst, asset, amount);
    }

    /**
     * @notice Withdraw an amount of asset from the protocol
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdraw(address asset, uint amount) override external {
        return withdrawInternal(msg.sender, msg.sender, msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw UniV3LPVault collateral by tokenId (only callable by the vault itself)
     * @param src The owner address
     * @param to The recipient address
     * @param asset The UniV3LPVault asset address
     * @param tokenId The NFT tokenId to withdraw
     */
    function withdrawCollateralWithTokenId(address src, address to, address asset, uint256 tokenId) override external {
        if (!isUniV3LPVaultAsset(asset)) revert Unauthorized();
        if (msg.sender != asset) revert Unauthorized(); // only the vault contract can call
        
        uint256 shares = IUniV3LPVault(asset).getTokenIdShares(tokenId);
        if (shares == 0) revert BadAsset(); // no shares for this tokenId

        uint256 tokenValueUsd = IUniV3LPVault(asset).getTokenIdValue(tokenId);
        if (tokenValueUsd == 0) revert BadPrice(); // value cannot be zero

        // Compute per-share price in feed decimals (8) using exact tokenId value
        // tokenValueUsd: 18 decimals, shares: 18 decimals → price: 8 decimals
        uint256 pricePerShare = (tokenValueUsd * 1e8) / shares;

        // Custom collateralization check using the exact tokenId value
        if (!isBorrowCollateralizedAfterRemovingTokenId(src, asset, safe128(shares), pricePerShare)) {
            revert NotCollateralized();
        }

        // Vault acts as operator; user must have allowed the vault (hasPermission check inside withdrawInternal)
        _skipCollateralCheck = true;
        withdrawInternal(msg.sender, src, to, asset, shares);
        _skipCollateralCheck = false;
    }

    /**
     * @notice Withdraw an amount of asset to `to`
     * @param to The recipient address
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdrawTo(address to, address asset, uint amount) override external {
        return withdrawInternal(msg.sender, msg.sender, to, asset, amount);
    }

    /**
     * @notice Withdraw an amount of asset from src to `to`, if allowed
     * @param src The sender address
     * @param to The recipient address
     * @param asset The asset to withdraw
     * @param amount The quantity to withdraw
     */
    function withdrawFrom(address src, address to, address asset, uint amount) override external {
        return withdrawInternal(msg.sender, src, to, asset, amount);
    }

    /**
     * @dev Withdraw either collateral or base asset, depending on the asset, if operator is allowed
     * @dev Note: Specifying an `amount` of uint256.max will withdraw all of `src`'s accrued base balance
     */
    function withdrawInternal(address operator, address src, address to, address asset, uint amount) internal nonReentrant {
        if (isWithdrawPaused()) revert Paused();
        if (!hasPermission(src, operator)) revert Unauthorized();

        if (asset == baseToken) {
            if (amount == type(uint256).max) {
                amount = balanceOf(src);
            }
            return withdrawBase(src, to, amount);
        } else {
            // For UniV3LPVault assets, only the vault itself is allowed to withdraw shares
            if (isUniV3LPVaultAsset(asset) && operator != asset) revert Unauthorized();
            return withdrawCollateral(src, to, asset, safe128(amount));
        }
    }

    /**
     * @dev Collateralization check after removing a specific UniV3LPVault tokenId
     * @param account The account being checked
     * @param asset The UniV3LPVault asset
     * @param sharesToRemove The shares corresponding to the tokenId
     * @param pricePerShare The per-share price in price feed decimals (8), derived from tokenId value
     */
    function isBorrowCollateralizedAfterRemovingTokenId(
        address account,
        address asset,
        uint128 sharesToRemove,
        uint256 pricePerShare
    ) internal view returns (bool) {
        int104 principal = userBasic[account].principal;

        if (principal >= 0) {
            return true;
        }

        uint16 assetsIn = userBasic[account].assetsIn;
        int liquidity = signedMulPrice(
            presentValue(principal),
            getPrice(baseTokenPriceFeed),
            uint64(baseScale)
        );

        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                if (liquidity >= 0) {
                    return true;
                }

                AssetInfo memory assetInfo = getAssetInfo(i);
                uint128 balanceStored = userCollateral[account][assetInfo.asset].balance;

                uint128 balanceToUse;
                uint256 assetPrice;

                if (assetInfo.asset == asset) {
                    if (balanceStored < sharesToRemove) revert BadAsset();
                    balanceToUse = balanceStored - sharesToRemove;
                    assetPrice = pricePerShare;
                } else {
                    balanceToUse = balanceStored;
                    assetPrice = isUniV3LPVaultAsset(assetInfo.asset)
                        ? getPriceForUser(assetInfo.priceFeed, account)
                        : getPrice(assetInfo.priceFeed);
                }

                uint newAmount = mulPrice(
                    balanceToUse,
                    assetPrice,
                    assetInfo.scale
                );
                liquidity += signed256(mulFactor(
                    newAmount,
                    assetInfo.borrowCollateralFactor
                ));
            }
            unchecked { i++; }
        }

        return liquidity >= 0;
    }

    /**
     * @dev Withdraw an amount of base asset from src to `to`, borrowing if possible/necessary
     */
    function withdrawBase(address src, address to, uint256 amount) internal {
        accrueInternal();

        UserBasic memory srcUser = userBasic[src];
        int104 srcPrincipal = srcUser.principal;
        int256 srcBalance = presentValue(srcPrincipal) - signed256(amount);
        int104 srcPrincipalNew = principalValue(srcBalance);

        (uint104 withdrawAmount, uint104 borrowAmount) = withdrawAndBorrowAmount(srcPrincipal, srcPrincipalNew);

        totalSupplyBase -= withdrawAmount;
        totalBorrowBase += borrowAmount;

        // Update cumulative net principal for interest calculation
        if (withdrawAmount > 0) {
            if (totalNetSupplyPrincipal[src] >= withdrawAmount) {
                totalNetSupplyPrincipal[src] -= withdrawAmount;
            } else {
                totalNetSupplyPrincipal[src] = 0;
            }
        }
        if (borrowAmount > 0) {
            totalNetBorrowPrincipal[src] += borrowAmount;
        }

        updateBasePrincipal(src, srcUser, srcPrincipalNew);

        if (srcBalance < 0) {
            if (uint256(-srcBalance) < baseBorrowMin) revert BorrowTooSmall();
            if (!isBorrowCollateralized(src)) revert NotCollateralized();
        }

        doTransferOut(baseToken, to, amount);

        emit Withdraw(src, to, amount);

        if (withdrawAmount > 0) {
            emit Transfer(src, address(0), presentValueSupply(baseSupplyIndex, withdrawAmount));
        }
    }

    /**
     * @dev Withdraw an amount of collateral asset from src to `to`
     */
    function withdrawCollateral(address src, address to, address asset, uint128 amount) internal {
        uint128 srcCollateral = userCollateral[src][asset].balance;
        uint128 srcCollateralNew = srcCollateral - amount;

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        
        // For UniV3LPVault assets, we need to check isBorrowCollateralized with the NEW balance
        // because the per-share price uses:
        //   perShare = userTotalValue / (walletShares + cometShares)
        // and we pass cometShares from userCollateral (already reduced). To make the check reflect
        // the post-withdraw state, we temporarily reduce userCollateral before calling the check.
        // For regular ERC20 assets, the order doesn't matter since price is independent of user balance.
        bool isUniV3LP = isUniV3LPVaultAsset(asset);
        
        if (isUniV3LP) {
            // Temporarily update balance and assetsIn for the check
            userCollateral[src][asset].balance = srcCollateralNew;
            updateAssetsIn(src, assetInfo, srcCollateral, srcCollateralNew);
            
            // Check if still collateralized with the new balance
            // Note: no accrue interest, BorrowCF < LiquidationCF covers small changes
            // This check uses the updated userCollateral balance, but getPriceForUser will still
            // use vault.balanceOf(src) which hasn't changed. However, since we're checking with
            // the reduced balance, the calculation should be conservative (if anything, it might
            // slightly overestimate the price, but the reduced balance should compensate).
            if (!_skipCollateralCheck && !isBorrowCollateralized(src)) {
                // Revert the temporary changes
                userCollateral[src][asset].balance = srcCollateral;
                updateAssetsIn(src, assetInfo, srcCollateralNew, srcCollateral);
                revert NotCollateralized();
            }
            
            // If check passes (or was pre-checked), update totals (balance already updated above)
            totalsCollateral[asset].totalSupplyAsset -= amount;
        } else {
            // For regular ERC20 assets, update balance first (order doesn't matter)
            totalsCollateral[asset].totalSupplyAsset -= amount;
            userCollateral[src][asset].balance = srcCollateralNew;
            updateAssetsIn(src, assetInfo, srcCollateral, srcCollateralNew);

            // Note: no accrue interest, BorrowCF < LiquidationCF covers small changes
            if (!isBorrowCollateralized(src)) revert NotCollateralized();
        }

        doTransferOut(asset, to, amount);

        emit WithdrawCollateral(src, to, asset, amount);
    }

    /**
     * @notice Absorb a list of underwater accounts onto the protocol balance sheet
     * @param absorber The recipient of the incentive paid to the caller of absorb
     * @param accounts The list of underwater accounts to absorb
     * @dev Only allowed liquidator contracts can call this function to prevent malicious users from stealing protocol assets
     */
    function absorb(address absorber, address[] calldata accounts) override external {
        if (isAbsorbPaused()) revert Paused();
        
        // Only allow trusted liquidator contracts to call absorb
        // This prevents malicious users from stealing protocol assets
        if (!allowedLiquidators[msg.sender]) revert Unauthorized();

        uint startGas = gasleft();
        accrueInternal();
        for (uint i = 0; i < accounts.length; ) {
            absorbInternal(absorber, accounts[i]);
            unchecked { i++; }
        }
        uint gasUsed = startGas - gasleft();

        // Note: liquidator points are an imperfect tool for governance,
        //  to be used while evaluating strategies for incentivizing absorption.
        // Using gas price instead of base fee would more accurately reflect spend,
        //  but is also subject to abuse if refunds were to be given automatically.
        LiquidatorPoints memory points = liquidatorPoints[absorber];
        points.numAbsorbs++;
        points.numAbsorbed += safe64(accounts.length);
        points.approxSpend += safe128(gasUsed * block.basefee);
        liquidatorPoints[absorber] = points;
    }

    /**
     * @dev Transfer user's collateral and debt to the protocol itself.
     */
    function absorbInternal(address absorber, address account) internal {
        if (!isLiquidatable(account)) revert NotLiquidatable();

        UserBasic memory accountUser = userBasic[account];
        int104 oldPrincipal = accountUser.principal;
        int256 oldBalance = presentValue(oldPrincipal);
        uint16 assetsIn = accountUser.assetsIn;

        uint256 basePrice = getPrice(baseTokenPriceFeed);
        uint256 deltaValue = 0;

        for (uint8 i = 0; i < numAssets; ) {
            if (isInAsset(assetsIn, i)) {
                AssetInfo memory assetInfo = getAssetInfo(i);
                address asset = assetInfo.asset;
                uint128 seizeAmount = userCollateral[account][asset].balance;
                userCollateral[account][asset].balance = 0;
                totalsCollateral[asset].totalSupplyAsset -= seizeAmount;

                // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
                uint256 assetPrice = isUniV3LPVaultAsset(asset)
                    ? getPriceForUser(assetInfo.priceFeed, account)
                    : getPrice(assetInfo.priceFeed);
                uint256 value = mulPrice(seizeAmount, assetPrice, assetInfo.scale);
                deltaValue += mulFactor(value, assetInfo.liquidationFactor);

                emit AbsorbCollateral(absorber, account, asset, seizeAmount, value);
                
                // If this is a UniV3LPVault, actually transfer NFTs to the absorber
                if (isUniV3LPVaultAsset(asset) && seizeAmount > 0) {
                    _liquidateUniV3LPVault(asset, account, absorber, seizeAmount);
                } else if (seizeAmount > 0) {
                    // For regular ERC20 assets, actually transfer the collateral to the absorber
                    doTransferOut(asset, absorber, seizeAmount);
                }
            }
            unchecked { i++; }
        }

        uint256 deltaBalance = divPrice(deltaValue, basePrice, uint64(baseScale));
        int256 newBalance = oldBalance + signed256(deltaBalance);
        // New balance will not be negative, all excess debt absorbed by reserves
        if (newBalance < 0) {
            newBalance = 0;
        }

        int104 newPrincipal = principalValue(newBalance);
        updateBasePrincipal(account, accountUser, newPrincipal);

        // reset assetsIn
        userBasic[account].assetsIn = 0;

        (uint104 repayAmount, uint104 supplyAmount) = repayAndSupplyAmount(oldPrincipal, newPrincipal);

        // Update cumulative net principal for interest calculation (liquidation case)
        if (repayAmount > 0) {
            totalNetBorrowPrincipal[account] = 0;
        }
        if (supplyAmount > 0) {
            totalNetSupplyPrincipal[account] += supplyAmount;
        }

        // Reserves are decreased by increasing total supply and decreasing borrows
        //  the amount of debt repaid by reserves is `newBalance - oldBalance`
        totalSupplyBase += supplyAmount;
        totalBorrowBase -= repayAmount;

        uint256 basePaidOut = unsigned256(newBalance - oldBalance);
        uint256 valueOfBasePaidOut = mulPrice(basePaidOut, basePrice, uint64(baseScale));
        emit AbsorbDebt(absorber, account, basePaidOut, valueOfBasePaidOut);

        if (newPrincipal > 0) {
            emit Transfer(address(0), account, presentValueSupply(baseSupplyIndex, unsigned104(newPrincipal)));
        }
    }

    /**
     * @notice Internal function to liquidate UniV3LPVault by transferring NFTs directly
     * @param vault The UniV3LPVault contract address
     * @param account The account being liquidated
     * @param absorber The absorber (liquidator) address
     * @param seizeAmount The amount of shares to liquidate
     * @dev This function liquidates NFTs by transferring them directly to the absorber
     *      It attempts to liquidate enough tokenIds to cover the seizeAmount
     */
    function _liquidateUniV3LPVault(
        address vault,
        address account,
        address absorber,
        uint128 seizeAmount
    ) internal nonReentrant {
        IUniV3LPVault vaultContract = IUniV3LPVault(vault);
        
        // Get all tokenIds owned by the account
        uint256[] memory tokenIds = vaultContract.getLiquidatableTokenIds(account);
        
        // Note: userCollateral[account][vault].balance has already been set to 0 in absorbInternal
        // The shares are already in Comet's balance (user deposited them to Comet)
        // We directly transfer NFTs to the absorber without requiring payment
        // The absorber will sell the NFTs and return base token to the protocol
        
        uint256 totalSharesLiquidated = 0;
        
        // Liquidate tokenIds in order until we've liquidated enough shares
        for (uint256 i = 0; i < tokenIds.length && totalSharesLiquidated < seizeAmount; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 tokenShares = vaultContract.getTokenIdShares(tokenId);
            
            if (tokenShares > 0) {
                // Transfer NFT directly to absorber without requiring payment
                // The absorber will handle selling the NFT and returning base token to protocol
                vaultContract.liquidateTransferNFT(
                    tokenId,
                    absorber,
                    bytes("")  // Empty payment data - no payment required
                );

                totalSharesLiquidated += tokenShares;
            }
        }
        
        // Note: If totalSharesLiquidated > seizeAmount, that's acceptable
        // The excess shares are effectively burned (they were already accounted for in value calculation)
    }

    /**
     * @notice Buy collateral from the protocol using base tokens, increasing protocol reserves
       A minimum collateral amount should be specified to indicate the maximum slippage acceptable for the buyer.
     * @param asset The asset to buy
     * @param minAmount The minimum amount of collateral tokens that should be received by the buyer
     * @param baseAmount The amount of base tokens used to buy the collateral
     * @param recipient The recipient address
     */
    function buyCollateral(address asset, uint minAmount, uint baseAmount, address recipient) override external nonReentrant {
        if (isBuyPaused()) revert Paused();

        int reserves = getReserves();
        if (reserves >= 0 && uint(reserves) >= targetReserves) revert NotForSale();

        // Note: Re-entrancy can skip the reserves check above on a second buyCollateral call.
        baseAmount = doTransferIn(baseToken, msg.sender, baseAmount);

        uint collateralAmount = quoteCollateral(asset, baseAmount);
        if (collateralAmount < minAmount) revert TooMuchSlippage();
        if (collateralAmount > getCollateralReserves(asset)) revert InsufficientReserves();

        // Note: Pre-transfer hook can re-enter buyCollateral with a stale collateral ERC20 balance.
        //  Assets should not be listed which allow re-entry from pre-transfer now, as too much collateral could be bought.
        //  This is also a problem if quoteCollateral derives its discount from the collateral ERC20 balance.
        doTransferOut(asset, recipient, safe128(collateralAmount));

        emit BuyCollateral(msg.sender, asset, baseAmount, collateralAmount);
    }

    /**
     * @notice Convert collateral amount to discounted base token amount
     * @param asset The collateral asset
     * @param collateralAmount The amount of collateral tokens
     * @return baseAmount The amount of base token required
     */
    function collateralToBase(address asset, uint collateralAmount) override public view returns (uint baseAmount) {
        if (collateralAmount == 0) {
            return 0;
        }

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        uint256 assetPrice = getPrice(assetInfo.priceFeed);
        uint256 basePrice = getPrice(baseTokenPriceFeed);
        uint256 discountFactor = mulFactor(storeFrontPriceFactor, FACTOR_SCALE - assetInfo.liquidationFactor);
        uint256 assetPriceDiscounted = mulFactor(assetPrice, FACTOR_SCALE - discountFactor);

        baseAmount = collateralAmount * assetPriceDiscounted * baseScale / (basePrice * assetInfo.scale);
    }

    function collateralToBaseForAccount(
        address asset,
        uint collateralAmount,
        address account
    ) override public returns (uint baseAmount) {
        if (collateralAmount == 0) {
            return 0;
        }

        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        // Only use user-specific price for UniV3LPVault (NFT), otherwise use standard price
        uint256 assetPrice = isUniV3LPVaultAsset(asset) 
            ? getPriceForUser(assetInfo.priceFeed, account)
            : getPrice(assetInfo.priceFeed);
        uint256 basePrice = getPrice(baseTokenPriceFeed);
        uint256 discountFactor = mulFactor(storeFrontPriceFactor, FACTOR_SCALE - assetInfo.liquidationFactor);
        uint256 assetPriceDiscounted = mulFactor(assetPrice, FACTOR_SCALE - discountFactor);

        baseAmount = collateralAmount * assetPriceDiscounted * baseScale / (basePrice * assetInfo.scale);
    }

    /**
     * @notice Gets the quote for a collateral asset in exchange for an amount of base asset
     * @param asset The collateral asset to get the quote for
     * @param baseAmount The amount of the base asset to get the quote for
     * @return The quote in terms of the collateral asset
     */
    function quoteCollateral(address asset, uint baseAmount) override public view returns (uint) {
        AssetInfo memory assetInfo = getAssetInfoByAddress(asset);
        uint256 assetPrice = getPrice(assetInfo.priceFeed);
        // Store front discount is derived from the collateral asset's liquidationFactor and storeFrontPriceFactor
        // discount = storeFrontPriceFactor * (1e18 - liquidationFactor)
        uint256 discountFactor = mulFactor(storeFrontPriceFactor, FACTOR_SCALE - assetInfo.liquidationFactor);
        uint256 assetPriceDiscounted = mulFactor(assetPrice, FACTOR_SCALE - discountFactor);
        uint256 basePrice = getPrice(baseTokenPriceFeed);
        // # of collateral assets
        // = (TotalValueOfBaseAmount / DiscountedPriceOfCollateralAsset) * assetScale
        // = ((basePrice * baseAmount / baseScale) / assetPriceDiscounted) * assetScale
        return basePrice * baseAmount * assetInfo.scale / assetPriceDiscounted / baseScale;
    }

    /**
     * @notice Set or remove a liquidator contract from the allowed list
     * @param liquidator The address of the liquidator contract
     * @param allowed Whether the liquidator is allowed to call absorb
     * @dev Only governor can call this function
     */
    function setAllowedLiquidator(address liquidator, bool allowed) external {
        if (msg.sender != governor) revert Unauthorized();
        if (liquidator == address(0)) revert BadAsset();
        
        allowedLiquidators[liquidator] = allowed;
        emit SetAllowedLiquidator(liquidator, allowed);
    }

    /**
     * @notice Withdraws base token reserves if called by the governor
     * @param to An address of the receiver of withdrawn reserves
     * @param amount The amount of reserves to be withdrawn from the protocol
     */
    function withdrawReserves(address to, uint amount) override external {
        if (msg.sender != governor) revert Unauthorized();

        int reserves = getReserves();
        if (reserves < 0 || amount > unsigned256(reserves)) revert InsufficientReserves();

        doTransferOut(baseToken, to, amount);

        emit WithdrawReserves(to, amount);
    }

    /**
     * @notice Sets Comet's ERC20 allowance of an asset for a manager
     * @dev Only callable by governor
     * @dev Note: Setting the `asset` as Comet's address will allow the manager
     * to withdraw from Comet's Comet balance
     * @dev Note: For USDT, if there is non-zero prior allowance, it must be reset to 0 first before setting a new value in proposal
     * @param asset The asset that the manager will gain approval of
     * @param manager The account which will be allowed or disallowed
     * @param amount The amount of an asset to approve
     */
    function approveThis(address manager, address asset, uint amount) override external {
        if (msg.sender != governor) revert Unauthorized();

        IERC20NonStandard(asset).approve(manager, amount);
    }

    /**
     * @notice Get the total number of tokens in circulation
     * @dev Note: uses updated interest indices to calculate
     * @return The supply of tokens
     **/
    function totalSupply() override external view returns (uint256) {
        (uint64 baseSupplyIndex_, ) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        return presentValueSupply(baseSupplyIndex_, totalSupplyBase);
    }

    /**
     * @notice Get the total amount of debt
     * @dev Note: uses updated interest indices to calculate
     * @return The amount of debt
     **/
    function totalBorrow() override external view returns (uint256) {
        (, uint64 baseBorrowIndex_) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        return presentValueBorrow(baseBorrowIndex_, totalBorrowBase);
    }

    /**
     * @notice Query the current positive base balance of an account or zero
     * @dev Note: uses updated interest indices to calculate
     * @param account The account whose balance to query
     * @return The present day base balance magnitude of the account, if positive
     */
    function balanceOf(address account) override public view returns (uint256) {
        (uint64 baseSupplyIndex_, ) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        int104 principal = userBasic[account].principal;
        return principal > 0 ? presentValueSupply(baseSupplyIndex_, unsigned104(principal)) : 0;
    }

    /**
     * @notice Query the current negative base balance of an account or zero
     * @dev Note: uses updated interest indices to calculate
     * @param account The account whose balance to query
     * @return The present day base balance magnitude of the account, if negative
     */
    function borrowBalanceOf(address account) override public view returns (uint256) {
        (, uint64 baseBorrowIndex_) = accruedInterestIndices(getNowInternal() - lastAccrualTime);
        int104 principal = userBasic[account].principal;
        return principal < 0 ? presentValueBorrow(baseBorrowIndex_, unsigned104(-principal)) : 0;
    }

    /**
     * @notice Fallback to calling the extension delegate for everything else
     */
    fallback() external payable {
        address delegate = extensionDelegate;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), delegate, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}