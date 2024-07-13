// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

abstract contract Helper is Test {
    address payable dev;
    address payable[] users;

    constructor() {
        Users helper = new Users();
        users = helper.create(20);
        dev = users[0];
    }
}

contract Users is Test {
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    function next() internal returns (address payable) {
        address payable user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    function create(uint256 num) external returns (address payable[] memory) {
        address payable[] memory users = new address payable[](num);
        for (uint256 i = 0; i < num; i++) {
            address payable user = next();
            vm.deal(user, 100 ether);
            users[i] = user;
        }
        return users;
    }
}
