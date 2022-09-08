pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    // 这三行代码定义了ERC20代币的三个对外状态变量（代币元数据）：名称，符号和精度。
    // 注意，由于该合约为交易对合约的父合约，而交易对合约是可以创建无数个的，所以这无数个交易对合约中的 ERC20 代币的名称、符号和精度都一样。
    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    uint8 public constant decimals = 18;

    uint  public totalSupply; // 记录代币发行总量的状态变量
    mapping(address => uint) public balanceOf;  //用一个 map 记录每个地址的代币余额
    mapping(address => mapping(address => uint)) public allowance; // 用来记录每个地址的授权分布, allowance[addressA][addressB]=addressA授权addressB可使用的代币额度

    // 用来在不同 Dapp 之间区分相同结构和内容的签名消息
    bytes32 public DOMAIN_SEPARATOR;
    // 这一行代码根据事先约定使用`permit`函数的部分定义计算哈希值，重建消息签名时使用。
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;// 记录合约中每个地址使用链下签名消息交易的数量，用来防止重放攻击。

    // ERC20 标准中的两个事件定义
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    /**
     * @dev: 构造函数
     * @notice: 构造函数只做了一件事，计算`DOMAIN_SEPARATOR`的值
     */
    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        /**
            * @dev: eip712Domain - 是一个名为`EIP712Domain`的 结构，它可以有以下一个或者多个字段：
            * @notice EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
            * @param {string} name 可读的签名域的名称，例如 Dapp 的名称，在本例中为代币名称
            * @param {string} version 当前签名域的版本，本例中为 "1"
            * @param {uint256} chainId 当前链的 ID，注意因为 Solidity 不支持直接获取该值，所以使用了内嵌汇编来获取
            * @param {address} verifyingContract 验证合约的地址，在本例中就是本合约地址
            */
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    /**
     * @dev: 进行代币增发
     * @notice: 它是`internal`函数(可在函数名前添加下划线，表示该函数为internal函数，下同)
     * @param {address} to
     * @param {uint} value 
     */
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    /**
     * @dev: 进行代币燃烧
     * @param {address} from
     * @param {uint} value 
     */
    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    /**
     * @dev: 进行授权操作, owner地址授权给spender地址value数量的token使用权
     * @param {address} owner
     * @param {address} spender
     * @param {uint} value 
     */
    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }


    /**
     * @dev: 转移代币操作, 将value数量的token从from地址转移给to地址
     * @param {address} from
     * @param {address} to
     * @param {uint} value 
     */
    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    /**
     * @dev: 授权代币操作的外部调用接口，msg.sender授权给spender地址value数量的token使用权
     * @param {address} from
     * @param {address} to
     * @param {uint} value 
     */
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev: 用户转移代币操作的外部调用接口。，将value数量的token从msg.sender地址转移给to地址
     * @param {address} from
     * @param {address} to
     * @param {uint} value 
     */
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev: 使用线下签名消息进行approve(授权)操作
     * @notice UniswapV2 的核心合约虽然功能完整，但对用户不友好，用户需要借助它的周边合约(v2-periphery)才能和核心合约交互
     * 比如用户减少流动性，此时用户需要将自己的流动性代币（一种 ERC20 代币）燃烧掉。由于用户调用的是周边合约，周边合约未经授权
     * 是无法进行燃烧操作的。此时，如果按照常规操作，用户需要首先调用交易对合约对周边合约进行授权，再调用周边合约进行燃烧，这个
     * 过程实质上是调用两个不同合约的两个交易（无法合并到一个交易中），它分成了两步，用户需要交易两次才能完成。
     * 使用线下消息签名后，可以减少其中一个交易，将所有操作放在一个交易里执行，确保了交易的原子性。
     * @param {address} owner, approve操作变量
     * @param {address} spender, approve操作变量
     * @param {address} value, approve操作变量
     * @param {address} deadline, 授权approve操作的截止时间
     * @param {address} v, 用户签名后，椭圆曲线相关数据，用于获取签名的用户地址
     * @param {address} 同v
     * @param {address} 同s
     */
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED'); //超过deadline则表示授权已失效
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
                // 每调用一次`permit`，相应地址的 nonce 就会加 1，
                // 这样再使用原来的签名消息就无法再通过验证了（重建的签名消息不正确了），用于防止重放攻击。
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);  //获取消息签名者的地址
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}
