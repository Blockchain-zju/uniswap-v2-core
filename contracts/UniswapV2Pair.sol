pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
/*
    UniswapV2 使用 _UQ112x112_ 是经过周密考虑的：
    1. 第一个使用的地方是使用它保存价格，剩下的 32 位保存溢出位。
    2. 第二个使用的地方是它使用 uint112 保存每种代币的 reserve，刚好剩下 32 位保存当前区块时间（虽然位数会不够）
*/
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol'; // 在获取交易对合约资产池的代币数量（余额）时使用。
import './interfaces/IUniswapV2Factory.sol'; // 导入`factory`合约相关接口，主要是用来获取开发团队手续费地址。
/* 有些第三方合约希望接收到代币后进行其它操作，好比异步执行中的回调函数。这里`IUniswapV2Callee`约定了
第三方合约如果需要执行回调函数必须实现的接口格式。当然了，定义了此接口后还可以进行`FlashSwap`。
*/
import './interfaces/IUniswapV2Callee.sol'; 

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    /*
        在 UniswapV2 中，价格为两种代币的数量比值，而在 Solidity 中，对非整数类型支持不好，
        通常两个无符号整数相除为地板除，会截断。为了提高价格精度，UniswapV2 使用 uint112 
        来保存交易对中资产的数量，而比值（价格）使用 UQ112x112 表示，一个代表整数部分，一个代表小数部分。
    */
    using UQ112x112 for uint224;

    /*
        Uniswap白皮书中解释：
        公式可确保**流动性池份额的价值永远不会低于该池中储备的几何平均值sqrt(x*y)**。但是，流动资金池份
        额的价值有可能随着时间的推移增长，这可以通过累积交易费用或通过向流动资金池的“捐赠”来实
        现。从理论上讲，这可能导致最小数量的流动性池份额（1e-18池份额）的价值过高，以至于小型流动
        性提供者无法提供任何流动性。
        为了缓解这一问题，Uniswap v2 在创建代币配对时，会烧掉 1e-15 (0.000000000000001) 个 
        LP Token(1000 倍最小数量的池份额 = 1000 wei)，然后将它们发送到零地址，而不是发送到铸造者。
        对于几乎所有令牌对来说，这应该是微不足道的成本。但是，这大大增加了上述攻击的成本。为了将流动资
        金池份额的价值提到100美元，攻击者需要向该池捐赠100,000美元，该资金将永久锁定为流动资金。
    */
    uint public constant MINIMUM_LIQUIDITY = 10**3; // 最小流动性。它是最小数值 1 的 1000 倍，**用来在提供初始流动性时燃烧掉。**
    /**
        用来计算标准 ERC20 合约中转移代币函数`transfer`的函数选择器。虽然标准的 ERC20 合约在转移代币后
        返回一个成功值，但有些不标准的并没有返回值。在这个合约里统一做了处理，并使用了较低级的`call`函数代
        替正常的合约调用。函数选择器用于`call`函数调用中。
     */
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 用来记录`factory`合约地址和交易对中两种代币的合约地址。
    address public factory;
    address public token0;
    address public token1;

    // 这三个状态变量记录了最新的恒定乘积中两种资产的数量和交易时的区块（创建）时间。
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    // 记录交易对中两种价格的累计值
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    //记录某一时刻恒定乘积中积的值，主要用于开发团队手续费计算
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    //用来防重入攻击
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }


    /**
     * @return 返回当前交易对的资产信息及最后交易的区块时间
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     * @dev: 使用`call`函数进行代币合约`transfer`的调用（使用了函数选择器）。
     * @notice:      它检查了返回值（首先必须调用成功，然后无返回值或者返回值为 true）。
     */
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /**
     * @dev: 构造函数
     */
    constructor() public {
        factory = msg.sender;
    }

    /**
     * @dev: 初始化函数
     * @notice: 因为`factory`合约使用`create2`函数创建交易对合约，无法向构造器传递参数，
                所以这里写了一个初始化函数用来记录合约中两种代币的地址。
     * @param {address} _token0: 交易对中token0的地址
     * @param {address} _token1: 交易对中token1的地址
     */
    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @dev: 用来更新 reserves，并且在每个 block 的第一次调用，更新价格累计值
     * @notice: 将保存的数值更新为实时代币余额，并同时进行价格累计的计算。
     * @param {uint} balance0: 当前合约token0的代币余额
     * @param {uint} balance1: 当前合约token1的代币余额
     * @param {uint112} _reserve0:  保存的恒定乘积中token0的数值
     * @param {uint112} _reserve1:  保存的恒定乘积中token1的数值
     */
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        //验证余额值不能大于 _uint112_ 类型的最大值，因为余额是 _uint256_ 类型的
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        //取模后，存32位的时间戳；这里可以不取模，因为取模操作和溢出后直接进行 Unit32 类型转换得到的结果是相同的
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);    
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);   //更新交易对中恒定乘积中的`reserve`的值
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;    //更新 block 时间为当前 block 时间（这样一个区块内价格只会累积计算一次）。
        emit Sync(reserve0, reserve1);
    }

    /**
     * @dev: 计算并发送开发团队手续费
     * @notice: 如果开发团队手续费打开后，用户每次交易手续费（0.3%）的 1/6 （0.05%）会分给开发团队，
     剩下的 5/6 才会发给流动性提供者。如果每次用户交易都计算并发送手续费，无疑会增加用户的 gas。Unisw
     ap 开发团队为了避免这种情况的出现，将开发团队手续费累积起来，在改变流动性时才发送
     * @notice: 由于资产交易手续费的存在，虽然是恒定乘积算法，但是这个乘积值`K`实质上是在慢慢变大的，
     于是这两个`K`之间就会有差额了。
     * @param {uint112} _reserve0: 交易对中token0的储备量
     * @param {uint112} _reserve1: 交易对中token1的储备量
     * @return {bool} feeOn: 手续费收取是否开启
     */
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); //获取开发团队手续费地址；
        feeOn = feeTo != address(0);    //根据手续费地址是否为零地址判断是否收取手续费
        uint _kLast = kLast; // gas savings //  使用一个局部变量记录过去某时刻的恒定乘积中的积的值。
        if (feeOn) {    //如果手续费开关打开，计算手续费的值，手续费以增发该交易对合约流动性代币的方式体现
            if (_kLast != 0) {  //当最近一次kLast有值时，才收取手续费。因为开关打开后只有先更新一次最新的`kLast`值有了比较才能继续计算。
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));     //手续费计算见白皮书2.4部分
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {   //如果手续费没开，则将_kLast设置为0。
            /*
            这么做的目的是因为手续费开关是可以重复打开关闭的。从后面的`mint`或者`burn`函数中，
            我们可以看到只有手续费打开才会更新这个`kLast`的值，关闭后是不会更新的。假定打开后
            再关闭，此时如果不设置`kLast`为 0，那它就是一个无法更新的旧值。然后我们再打开开关，
            此时`kLast`是一个很久前的旧值，而不是最近更新的值，而使用旧值会将开关再次打开前的
            数据也计算进去（而不是从开关打开的那一时刻开始计算）。
            */
            kLast = 0;
        }
    }

    /**
     * @dev: 在用户提供流动性时（提供一定比例的两种 ERC20 代币到交易对）增发流动性代币给提供者
     * @notice: 这个低等级函数应该从一个合约调用，并且需要执行重要的安全检查
     * @notice: 理解难点：最小流动性
     * @param {address} to: 流动性提供者
     * @return {uint} liquidity: 手续费收取是否开启
     */
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings, 用来获取当前交易对的`reverse`
        uint balance0 = IERC20(token0).balanceOf(address(this));    //获取当前合约注入的两种资产的实际数量
        uint balance1 = IERC20(token1).balanceOf(address(this));    
        uint amount0 = balance0.sub(_reserve0); //获取当前两种资产的流动性提供量
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);    //发送开发团队手续费（如果相应开关打开的了话），以LPtoken增发的形式收取手续费
        //因为`_mintFee`函数可能更新已发行流动性代币的数量，所以必须在它之后赋值
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // 直接使用 Math.sqrt(amount0.mul(amount1)) 为总流动性，会导致一个漏洞：
            // 为了垄断交易对，早期的流动性参与者可以刻意抬高流动性单价，使得散户无力参与，即无法提供流动性
            // 刻意提高流动性单价操作见: https://godorz.info/2021/09/uniswap-v2-core-1/
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 由于注入了两种代币，所以会有两个计算公式，每种代币按比例计算一次增发的流动性数量，取其中的最小值。
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 增发的流动性必须大于 0，等于 0 相当于无增发，白做无用功。
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);// 增发新的流动性给接收者

        _update(balance0, balance1, _reserve0, _reserve1);  // 更新当前保存的恒定乘积中两种资产的值
        // 如果手续费打开了，更新最近一次的乘积值。该值不随平常的代币交易更新，仅用来流动性供给时计算开发团队手续费。
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @dev: 通过燃烧流动性代币的形式来提取相应的两种资产，从而减小该交易对的流动性
     * @notice: 这个低等级函数应该从一个合约调用，并且需要执行重要的安全检查
     * @param {address} to: 代币接收者的地址
     * @return {uint} amount0: 可提取token0的代币数量
     * @return {uint} amount1: 可提取token0的代币数量
     */
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 前三行用来获取交易对的 reverse 及代币地址，并保存在局部变量中，注释中提到也是为了节省 gas
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));//获取交易对合约地址拥有两种代币的实际数量
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];// 获取事先转入的流动性的数值

        bool feeOn = _mintFee(_reserve0, _reserve1); //收取手续费，如果仅在注入资产时计算并发送手续费，接下来用户提取资产时就会计算不准确
        //因为`_mintFee`函数可能更新已发行流动性代币的数量，所以必须在它之后赋值
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //按比例计算提取资产
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED'); // 最小燃烧值需求
        _burn(address(this), liquidity); // 将用户事先转入的流动性燃烧掉。因为此时流动性代币已经转移到交易对，所以燃烧的地址为`address(this)`。
        _safeTransfer(_token0, to, amount0);    //将相应数量的 ERC20 代币发送给接收者
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this)); // 重新获取了交易对合约地址拥有的两种代币的余额
        balance1 = IERC20(_token1).balanceOf(address(this)); // 相比于直接计算“原余额-提取代币数量”，直接读取合约数据相对准确

        _update(balance0, balance1, _reserve0, _reserve1); // 更新当前保存的恒定乘积中两种资产的值，同`mint`函数
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date, 更新`KLast`的值，同`mint`函数
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @dev: 实现交易对中资产（ERC20 代币）交易的功能，也就两种 ERC20 代币互相买卖，而多个交易对可以组成一个交易链
     * @notice: 这个低等级函数应该从一个合约调用，并且需要执行重要的安全检查
     * @param {uint} amount0Out: 购买的 token0 的数量
     * @param {uint} amount1Out: 购买的 token1 的数量
     * @param {address} to: 代币接收者的地址          
     * @param {bytes} data: 接收后执行回调时的传递数据
     */
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 至少要购买一种token，其数量大于0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        //获取swap之前的token0和token1的余额，于节约gas，将变量存储为局部变量，但是会占用stack位置，
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        // 为防止栈位过深，这里使用花括号作为局部作用域，其中局部变量_token0和_token1在{}花括号作用域结束后，相应栈位即释放
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        // 验证接收者地址不能为 token 地址
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // 整个swap过程中，这里先行转出购买资产
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 闪电兑-执行用户定义的回调合约，在乐观转账给address To和确保K值不减之间时调用
        // 如果参数 data 不为空，那么执行调用合约的`uniswapV2Call`回调函数并将 data 传递过去，普通交易调用时这个 data 为空
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        // 获取交易对合约地址两种代币的余额，这两个变量定义在{}局部作用域之外，栈位不释放
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 通过余额的差值计算得到要交换的Token数量
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 必须转入某种资产（大于 0）才能交易成另一种资产
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        //扣除手续费，验证转账后的余额满足 X*Y >= K的要求
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        // 更新余额记录账本
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
    /**
     * @dev: 强制交易对合约中两种代币的实际余额和保存的恒定乘积中的资产数量一致（多余的发送给调用者）
     * @notice: 任何人都可以调用该函数来获取额外的资产（前提是如果存在多余的资产）
     * @param {address} to: 
     */
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /**
     * @dev: 和`skim`函数刚好相反，强制保存的恒定乘积的资产数量为交易对合约中两种代币的实际余额
     * @notice: 用于处理一些特殊情况。通常情况下，交易对中代币余额和保存的恒定乘积中的资产数量是相等的。
     * @param {address} to: 
     */
    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
