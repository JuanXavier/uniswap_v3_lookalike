https://github.com/Jeiwan/uniswapv3-code/tree/milestone_1

$ params='{"from":"0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266 ,"to":"0xe7f1725e7734ce288f8367e1bb143e90bb3f0512 ,"data":"0x70a08231000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266"}'
$ curl -X POST -H 'Content-Type: application/json' \
 --data '{"id":1,"jsonrpc":"2.0","method":"eth_call","params":['"$params"',"latest"]}' \
 http://127.0.0.1:8545
{"jsonrpc":"2.0","id":1,"result":"0x00000000000000000000000000000000000000000000011153ce5e56cf880000"}

WETH address 0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f  
 USDC address 0x4A679253410272dd5232B3Ff7cF5dbB88f295319  
 Pool address 0x7a2088a1bFc9d81c55368AE168C2C02570cB814F  
 Manager address 0x09635F643e140090A9A8Dcd712eD6285858ceBef

0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266

cast --from-wei(cast --to-dec (cast call 0x4A679253410272dd5232B3Ff7cF5dbB88f295319 "balanceOf(address)" 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266))
