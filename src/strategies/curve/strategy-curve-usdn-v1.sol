// SPDX-License-Identifier: MIT
// Author: purplezky
// TODO: come up with a way to distribute the 10% dev fee to the victims of the pDAI hack and distributed according to their pDAI jar share
pragma solidity ^0.6.2;

import "../../lib/erc20.sol";
import "../../lib/safe-math.sol";

import "./scrv-voter.sol";
import "./crv-locker.sol";

import "../../interfaces/jar.sol";
import "../../interfaces/curve.sol";
import "../../interfaces/uniswapv2.sol";
import "../../interfaces/controller.sol";

import "../strategy-base.sol";

contract StrategyCurveUSDNv1 is StrategyBase {
    // Curve
    address public usdn3CRV = 0x4f3E8F405CF5aFC05D68142F3783bDfE13811522;
    address public usdn_gauge = 0xF98450B5602fa59CC66e1379DFfB6FDDc724CfC4;
    address public usdn_pool = 0x0f9cb53Ebe405d49A0bbdBD291A65Ff571bC83e1;

    // curve dao
    address public gauge;
    address public curve;

    // tokens we're farming
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // stablecoins
    address public dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public usdn = 0x674C6Ad92Fd080e4004b2312b45f796a192D27a0;

    // How much CRV tokens to keep
    uint256 public keepCRV = 500;
    uint256 public keepCRVMax = 10000;

    // crv-locker and voter
    address public usdn3CRVVoter;
    address public crvLocker;

    constructor(
        address _usdn3CRVVoter,
        address _crvLocker,
        address _governance,
        address _strategist,
        address _controller,
        address _timelock
    )
        public
        StrategyBase(usdn3CRV, _governance, _strategist, _controller, _timelock)
    {
        curve = usdn_pool;
        gauge = usdn_gauge;

        usdn3CRVVoter = _usdn3CRVVoter;
        crvLocker = _crvLocker;
    }

    // **** Getters ****

    function balanceOfPool() public override view returns (uint256) {
        return SCRVVoter(usdn3CRVVoter).balanceOf(gauge);
    }

    function getName() external override pure returns (string memory) {
        return "StrategyUSDNv1";
    }

    function getHarvestable() external returns (uint256) {
        return ICurveGauge(gauge).claimable_tokens(crvLocker);
    }

    function getMostPremium() public view returns (address, uint8) {
        uint256[] memory balances = new uint256[](4);
        balances[0] = ICurveFi_4(curve).balances(0); // DAI
        balances[1] = ICurveFi_4(curve).balances(1).mul(10**12); // USDC
        balances[2] = ICurveFi_4(curve).balances(2).mul(10**12); // USDT
        balances[3] = ICurveFi_4(curve).balances(3); // USDN

        // DAI
        if (
            balances[0] < balances[1] &&
            balances[0] < balances[2] &&
            balances[0] < balances[3]
        ) {
            return (dai, 0);
        }

        // USDC
        if (
            balances[1] < balances[0] &&
            balances[1] < balances[2] &&
            balances[1] < balances[3]
        ) {
            return (usdc, 1);
        }

        // USDT
        if (
            balances[2] < balances[0] &&
            balances[2] < balances[1] &&
            balances[2] < balances[3]
        ) {
            return (usdt, 2);
        }

        // USDN
        if (
            balances[3] < balances[0] &&
            balances[3] < balances[1] &&
            balances[3] < balances[2]
        ) {
            return (usdn, 3);
        }

        // If they're somehow equal, we just want DAI
        return (dai, 0);
    }

    // **** Setters ****

    function setKeepCRV(uint256 _keepCRV) external {
        require(msg.sender == governance, "!governance");
        keepCRV = _keepCRV;
    }

    // **** State Mutations ****

    function deposit() public override {
        uint256 _want = IERC20(want).balanceOf(address(this));
        if (_want > 0) {
            IERC20(want).safeTransfer(usdn3CRVVoter, _want);
            SCRVVoter(usdn3CRVVoter).deposit(gauge, want);
        }
    }

    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        return SCRVVoter(usdn3CRVVoter).withdraw(gauge, want, _amount);
    }

    function harvest() public override onlyBenevolent {
        // Anyone can harvest it at any given time.
        // I understand the possibility of being frontrun / sandwiched
        // But ETH is a dark forest, and I wanna see how this plays out
        // i.e. will be be heavily frontrunned/sandwiched?
        //      if so, a new strategy will be deployed.

        // stablecoin we want to convert to
        (address to, uint256 toIndex) = getMostPremium();

        // Collects crv tokens
        // Don't bother voting in v1
        SCRVVoter(usdn3CRVVoter).harvest(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            // How much CRV to keep to restake?
            uint256 _keepCRV = _crv.mul(keepCRV).div(keepCRVMax);
            IERC20(crv).safeTransfer(address(crvLocker), _keepCRV);

            // How much CRV to swap?
            _crv = _crv.sub(_keepCRV);
            _swapUniswap(crv, to, _crv);
        }

        // Adds liquidity to curve.fi's usdn pool
        // to get back want (usdn3CRV)
        uint256 _to = IERC20(to).balanceOf(address(this));
        if (_to > 0) {
            IERC20(to).safeApprove(curve, 0);
            IERC20(to).safeApprove(curve, _to);
            uint256[4] memory liquidity;
            liquidity[toIndex] = _to;
            ICurveFi_4(curve).add_liquidity(liquidity, 0);
        }

        // We want to get back sCRV
        _distributePerformanceFeesAndDeposit();
    }
}
