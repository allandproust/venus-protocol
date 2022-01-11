pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "../VBep20.sol";
import "../VToken.sol";
import "../EIP20Interface.sol";
import "../PriceOracle.sol";
import "../ErrorReporter.sol";
import "../Comptroller.sol";

contract ComptrollerLens is ComptrollerErrorReporter, ExponentialNoError {
    /** VAI repay Calculations **/
    function getVAIRepayRate(address comptroller) public view returns (uint) {
        uint rate = 1e18;
        uint baseRateMantissa = Comptroller(comptroller).baseRateMantissa();
        uint floatRateMantissa = Comptroller(comptroller).floatRateMantissa();
        if (baseRateMantissa > 0) {
            if (floatRateMantissa > 0) {
                uint oraclePrice = Comptroller(comptroller)
                    .oracle()
                    .assetPrices(Comptroller(comptroller).vaiController().getVAIAddress());
                if (1e18 >= oraclePrice) {
                    uint delta;
                    delta = sub_(1e18, oraclePrice, "VAI_REPAY_RATE_CALCULATION_FAILED");
                    delta = mul_(delta, floatRateMantissa, "VAI_REPAY_RATE_CALCULATION_FAILED");
                    delta = div_(delta, 1e18, "VAI_REPAY_RATE_CALCULATION_FAILED");
                    rate = add_(rate, delta, "VAI_REPAY_RATE_CALCULATION_FAILED");
                }
            }
            rate = add_(rate, baseRateMantissa);
        }
        return rate;
    }

    /**
     * @dev Get the VAI actual total amount of repayment by the user
     */
    function getVAIRepayAmount(address comptroller, address account) public view returns (uint) {
        uint amount = Comptroller(comptroller).mintedVAIs(account);
        uint rate = getVAIRepayRate(comptroller);
        amount = mul_(rate, amount, "VAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");
        amount = div_(amount, 1e18, "VAI_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");
        return amount;
    }

    /**
     * @dev Calculate the VAI amount of principal repayment
     */
    function getVAICalculateRepayAmount(address comptroller, address account, uint repayAmount) public view returns (uint) {
        uint amount = repayAmount;
        uint totalRepayAmount = getVAIRepayAmount(comptroller, account);
        
        if(totalRepayAmount >= repayAmount) {
            uint rate = getVAIRepayRate(comptroller);
            repayAmount = mul_(repayAmount, 1e18, "VAI_REPAY_AMOUNT_CALCULATION_FAILED");
            amount = div_(repayAmount, rate, "VAI_REPAY_AMOUNT_CALCULATION_FAILED");
        } else {
            amount = Comptroller(comptroller).mintedVAIs(account);
        }

        return amount;
    }


    /** liquidate seize calculation **/
    function liquidateCalculateSeizeTokens(
        address comptroller, 
        address vTokenBorrowed, 
        address vTokenCollateral, 
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(VToken(vTokenBorrowed));
        uint priceCollateralMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(VToken(vTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = VToken(vTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: Comptroller(comptroller).liquidationIncentiveMantissa()}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }


    function liquidateVAICalculateSeizeTokens(
        address comptroller,
        address vTokenCollateral, 
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = 1e18;  // Note: this is VAI
        uint priceCollateralMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(VToken(vTokenCollateral));
        if (priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = VToken(vTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: Comptroller(comptroller).liquidationIncentiveMantissa()}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /** liquidity calculation **/
    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `vTokenBalance` is the number of vTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint vTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        VToken vTokenModify,
        uint redeemTokens,
        uint borrowAmount) external view returns (uint, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        VToken[] memory assets = Comptroller(comptroller).getAssetsIn(account);
        for (uint i = 0; i < assets.length; i++) {
            VToken asset = assets[i];

            // Read the balances and exchange rate from the vToken
            (oErr, vars.vTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0, 0);
            }
            (, uint collateralFactorMantissa,) = Comptroller(comptroller).markets(address(asset));
            vars.collateralFactor = Exp({mantissa: collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> bnb (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * vTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.vTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with vTokenModify
            if (asset == vTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        vars.sumBorrowPlusEffects = add_(vars.sumBorrowPlusEffects, getVAIRepayAmount(comptroller, account));

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (uint(Error.NO_ERROR), vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (uint(Error.NO_ERROR), 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

}

