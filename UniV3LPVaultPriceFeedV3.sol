// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import "../PriceFeedBase.sol";
import "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/INFTLP.sol";
import "./UniV3LPVault.sol";

/**
 * @title UniV3LPVaultPriceFeedV3
 * @notice User-specific price feed that calculates prices on-demand
 * @dev This price feed calculates user-specific prices in real-time by calling getUserTotalValue
 *      No caching is used - prices are always fresh and accurate
 *      This eliminates the need for off-chain price updates
 */
contract UniV3LPVaultPriceFeedV3 is PriceFeedBase {
    /// @notice Version of the price feed
    uint256 public constant override version = 3;
    
    /// @notice The vault contract
    UniV3LPVault public immutable vault;
    
    /// @notice Price feed decimals (8 for Chainlink USD feeds)
    uint8 public constant override decimals = 8;
    
    /// @notice Description of the price feed
    string public override description;
    
    
    /**
     * @notice Construct a new price feed
     * @param _vault The UniV3LPVault contract address
     * @param _description Description of the price feed
     */
    constructor(
        address _vault,
        string memory _description
    ) {
        require(_vault != address(0), "Invalid vault");
        
        vault = UniV3LPVault(_vault);
        description = _description;
    }
    
    /**
     * @notice Calculate the fallback price (average price) for the vault
     * @return price The average price per token (8 decimals)
     * @dev This is used when user-specific price cannot be calculated
     */
    function _calculateFallbackPrice() internal view returns (uint256 price) {
        uint256 totalValueCached = vault.totalValue();
        uint256 totalSupply = vault.totalSupply();
        
        if (totalSupply == 0) {
            return 0;
        }
        
        // totalValue is in 18 decimals, totalSupply is in 18 decimals
        // price should be in 8 decimals
        return (totalValueCached * 1e8) / totalSupply;
    }
    
    /**
     * @notice Get the latest round data (fallback to average price)
     * @return roundId The round ID
     * @return answer The price per vault token in USD (8 decimals)
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     * @dev This function returns the average price for backward compatibility
     *      For user-specific prices, use latestRoundDataForUser() instead
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Return average price for backward compatibility
        uint256 priceToUse = _calculateFallbackPrice();
        
        // Set metadata
        roundId = uint80(block.number);
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
        
        // Ensure price fits in int256
        require(priceToUse <= uint256(type(int256).max), "Price overflow");
        answer = int256(priceToUse);
    }
    
    /**
     * @notice Get the latest round data for a specific user
     * @param user The user address to get the price for
     * @return roundId The round ID
     * @return answer The price per vault token in USD (8 decimals)
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     * @dev This function calculates the user-specific price on-demand by calling getUserTotalValue
     *      No caching is used - prices are always fresh and accurate
     *      This eliminates the need for off-chain price updates
     */
    function latestRoundDataForUser(address user)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Use total shares corresponding to all positions owned by the user
        // This includes shares held directly and shares supplied to Comet
        uint256 userShares = vault.getUserTotalShares(user);
        uint256 priceToUse;
        
        // Calculate user-specific price on-demand
        uint256 userValue = vault.getUserTotalValue(user);
        
        // userValue is in 18 decimals, userShares is in 18 decimals
        // price should be in 8 decimals
        if (userShares > 0) {
            priceToUse = (userValue * 1e8) / userShares;
        } else {
            // Fallback to average price if shares is 0 (shouldn't happen due to check above)
            priceToUse = _calculateFallbackPrice();
        }
    
        
        // Set metadata
        roundId = uint80(block.number);
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
        
        // Ensure price fits in int256
        require(priceToUse <= uint256(type(int256).max), "Price overflow");
        answer = int256(priceToUse);
    }
}

