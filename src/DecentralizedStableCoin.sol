// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Starkxun
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // 当操作的数量小于或等于零时抛出
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    // 当销毁的代币数量超过持有者的余额时抛出
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    // 当传入的地址为零地址时抛出
    error DecentralizedStableCoin__NotZeroAddress();

    /*
    In future versions of OpenZeppelin contracts package, Ownable must be declared with an address of the contract owner
    as a parameter.
    For example:
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) {}
    Related code changes can be viewed in this commit:
    https://github.com/OpenZeppelin/openzeppelin-contracts/commit/13d5e0466a9855e9305119ed383e54fc913fdc60
    */

    // 初始化 ERC20 代币，设置代币名称为 DecentralizedStableCoin，符号为 DSC
    // Ownable(initialOwner)：设置合约的初始拥有者为 initialOwner 地址
    constructor(address initialOwner) ERC20("DecentralizedStableCoin", "DSC") Ownable(initialOwner) {}

    // 可销毁代币的函数，只有合约的拥有者（Owner）可以调用
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        // 检查销毁的数量是否大于零，否则抛出错误
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        // 检查调用者的余额是否足够销毁，否则抛出错误
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        // 调用父合约的 burn 函数执行销毁操作
        super.burn(_amount);
    }

    // 用于铸造新代币的函数，只有合约的拥有者（Owner）可以调用
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // 检查目标地址是否为零地址，否则抛出错误
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        // 检查铸造的数量是否大于零，否则抛出错误
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        // 调用父合约的 _mint 函数执行铸造操作，并返回 true 表示成功
        _mint(_to, _amount);
        return true;
    }
}
