// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockRouter {
    using SafeERC20 for IERC20;

    address public immutable WETH;
    uint256 public bnbPerTokenRate;

    constructor(address weth_, uint256 bnbPerTokenRate_) {
        WETH = weth_;
        bnbPerTokenRate = bnbPerTokenRate_;
    }

    receive() external payable {}

    function setBnbPerTokenRate(uint256 rate) external {
        bnbPerTokenRate = rate;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * bnbPerTokenRate / 1 ether;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp, "EXPIRED");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * bnbPerTokenRate / 1 ether;
        require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        (bool ok,) = payable(to).call{value: amountOut}("");
        require(ok, "ETH_SEND_FAILED");
    }
}
