pragma solidity =0.5.16;
import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;   // 收取手续费的地址
    address public feeToSetter; // 设置feeTo的权限者地址

    // tokenA和tokenB的交易对地址存储(tokenA[tokenB] = pair)
    mapping(address => mapping(address => address)) public getPair; // 获取交易对的pair地址
    address[] public allPairs;  // 用来储存所有的pair

    // 定义交易对创建事件,返回参数tokenA地址,tokenB地址,pair地址,allPairs长度(第几个交易对)
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    
    /**
     * @dev: 构造函数
     * @param {address} _feeToSetter: 手续费控制的权限者地址
     */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    /**
     * @return 返回交易对的数量
     */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /**
     * @dev: 创建tokenA和tokenB的交易对并获得pair地址
     * @param {address} tokenA
     * @param {address} tokenB
     * @return {address} 返回对应的pair地址
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        //判断tokenA不等于tokenB
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');    
        // 将tokenA和tokenB进行比大小,如果tokenA小于tokenB，则交换给token0和token1
        // 因为地址的底层是uint160,所以有大小排序
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 判断token0不能为0地址
        // 此时判断token0就等于同时判断了token0和token1,因为tokenA和tokenB已经进行过大小判断,token0地址是绝对小于任何地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 判断token0是否和token1有产生过交易对,如果没配对那么mapping就是0地址,如果非0地址代表已经配对过了
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // 表达式type(x)可用于检索参数x的类型信息(x仅能是合约或整型常量)
        // type(x).creationCode 获得包含x的合约的bytecode,是bytes类型(不能在合约本身或继承的合约中使用,因为会引起循环引用)
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 将排序好的token对进行打包后通过keccak256得到hash值
        // 因为两个地址是为确定值,所以salt是可以通过链下计算出来
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // 内联汇编
        assembly {
            /**
             * @dev: create2方法 - 在已知交易对及salt的情况下创建一个新的交易对,返回新的交易对地址(针对此算法可以提前知道交易对的地址)
             * @notice 转注释2
             * @notice create2(V, P, N, S) - V: 发送V数量wei以太,P: 起始内存地址,N: bytecode长度,S: salt
             * @param {uint} 指创建合约后向合约发送x数量wei的以太币
             * @param {bytes} add(bytecode, 32) opcode的add方法,将bytecode偏移后32位字节处,因为前32位字节存的是bytecode长度
             * @param {bytes} mload(bytecode) opcode的方法,获得bytecode长度
             * @param {bytes} salt 盐值
             * @return {address} 返回新的交易对地址
             */
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 将新的交易对地址初始化到pair合约中(因为create2函数创建合约时无法提供构造函数参数)
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 将token0和token1的交易对地址设置到mapping中(0和1的双向交易对)
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 将新的交易对地址添加到allPairs数组中
        allPairs.push(pair);
        // 触发交易对创建事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
     * @dev: 设置团队手续费开关
     * @notice 在uniswapV2中,用户交易代币时,会被收取交易额的千分之三手续费分配给所有流动性提供者.
     * @param {address} 不为零地址,则代表开启手续费开关(手续费中的1/6分给此地址),为零地址则代表关闭手续费开关
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
     * @dev: 转让设置feeTo的权限者
     * @notice 转注释1
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    /**
        @dev: 注释1
        在转让权限时可能会出现一个情况,当管理员进行转让时可能输入错误的地址,正常情况下这种情况发生后将不可更改,并且将丧失永久管理权.
        有一种方法可以解决这类问题,就是使用一个中间地址值过渡一下,而被新设置owner的对象需要再调用一次方法才能完成权限的转移.
        如果原管理员发现转移地址错误了,可在目标错误地址未进行确认时及时更改过来
        address public owner;
        address public newOwner;
        // 进行转移权限到newOwner,如果发现错误可再一次设置
        function transferOwnership(address _newOwner) public onlyOwner {
            newOwner = _newOwner;
        }
        // 被转移权限的需调用此方法来确认接受此权限,此时将完成权限转移的设置
        function acceptOwnership() public {
            require(msg.sender == newOwner,"invalid operation");
            emit OwnershipTransferred(owner, newOwner);
            owner = newOwner;
            newOwner = address(0);
        }
     */

     /** 
        @dev: 注释2
        create2的知识扩展:
            因为以太坊evm中账号的内存管理是每个账号(包含合约)都有一个内存区域,该区域是线性的并且在字节等级上寻址,但是读取限定为256位(32字节)大小,写的时候可以为8位(1字节)或256位(32字节)大小.
            solidity中内联汇编访问本地变量时,如果本地变量为值类型,则直接使用该值;如果本地变量是引用类型(memory或calldata),则会使用memory或calldata中的内存地址,而不是值本身.
            solidity中动态大小的字节数组,是引用类型,类似string也是引用类型.
            所以在create2函数调用时使用了type(x).creationCode 来获得了x合约的bytecode,类型为bytes为引用类型.根据上述的内存读取限制和内联汇编访问本地引用类型的规则,它在内联汇编中的实际值为该字节数组的内存地址.
            因为bytecode开始的32字节存储的是creationCode的长度,从第二个32字节开始才是存的实际creationCode内容,所以create2函数中的第二个参数需要为实际creationCode内容,才进行了add(bytecode, 32)的方式将值偏移到后32字节后.

        create2的solidity方法:
            因为内联汇编的可读性较为差些,所以在solidity的0.6.1以上新增了加盐创建合约的create2方法,该方法直接通过new在合约类型后面加上salt选项来进行自定义加盐的合约创建,等效于内联汇编中的create2函数.
            示例代码:
                // SPDX-License-Identifier: GPL-3.0
                pragma solidity ^0.7.0;

                contract D {
                    uint public x;
                    constructor(uint a) {
                        x = a;
                    }
                }

                contract C {
                    function createDSalted(bytes32 salt, uint arg) public {
                        /// 这个复杂的表达式只是告诉我们，如何预先计算地址。
                        /// 这里仅仅用来说明。
                        /// 实际上，你仅仅需要 ``new D{salt: salt}(arg)``.
                        address predictedAddress = address(uint160(uint(keccak256(abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(abi.encodePacked(
                                type(D).creationCode,
                                arg
                            ))
                        )))));

                        D d = new D{salt: salt}(arg);
                        require(address(d) == predictedAddress);
                    }
                }
    */
}
