pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./VToken.sol";

interface ComptrollerLensInterface {
    function liquidateCalculateSeizeTokens(
        address comptroller, 
        address vTokenBorrowed, 
        address vTokenCollateral, 
        uint actualRepayAmount
    ) external view returns (uint, uint);
    function liquidateVAICalculateSeizeTokens(
        address comptroller,
        address vTokenCollateral, 
        uint actualRepayAmount
    ) external view returns (uint, uint);
    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        VToken vTokenModify,
        uint redeemTokens,
        uint borrowAmount) external view returns (uint, uint, uint);
    function getVAIRepayAmount(address comptroller, address account) external view returns (uint);
    function getVAICalculateRepayAmount(address comptroller, address account, uint repayAmount) external view returns (uint);
}
