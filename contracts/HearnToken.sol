// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./libs/ERC20.sol";
import "./libs/IUniswapAmm.sol";
import "./LiquidifyHelper.sol";

contract HearnToken is ERC20("HEARN", "HEARN") {
    using SafeMath for uint256;
    using Address for address;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ZERO = address(0);
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    
    uint16 public MaxLiqFee = 3000; // 30% max
    uint16 public MaxMarketingFee = 3000; // 30% max

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isExcludedFromAntiBot;

    uint256 public constant MAX_TX_AMOUNT_MIN_LIMIT = 1 ether;
    uint256 public constant MAX_WALLET_AMOUNT_MIN_LIMIT = 100 ether;
    uint256 public _maxTxAmount = 10000 ether;
    uint256 public _maxWalletAmount = 100000 ether;

    uint16 public _liquidityFee = 1000; // Fee for Liquidity
    uint16 public _marketingFee = 1000; // Fee for Marketing

    IUniswapV2Router02 public _swapRouter;
    address public _hearnBnbPair;
    address public _hearnBusdPair;

    address public _marketingWallet;
    address private _operator;

    bool _inSwapAndLiquify;
    bool public _swapAndLiquifyEnabled = true;

    uint256 public _numTokensSellToAddToLiquidity = 1000 ether;

    LiquidifyHelper public _liquidifyHelper;

    event OperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event LiquifyAndBurned(
        uint256 tokensSwapped,
        uint256 busdReceived,
        uint256 tokensIntoLiqudity
    );
    event MarketingFeeTrasferred(
        address indexed marketingWallet,
        uint256 tokensSwapped,
        uint256 busdAmount
    );

    modifier lockTheSwap() {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    modifier onlyOperator() {
        require(
            operator() == _msgSender(),
            "HEARN: caller is not the operator"
        );
        _;
    }

    constructor() payable {
        _marketingWallet = _msgSender();
        _operator = _msgSender();

        _swapRouter = IUniswapV2Router02(
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        );
        // Create a uniswap pair for this new token
        _hearnBnbPair = IUniswapV2Factory(_swapRouter.factory()).createPair(
            address(this),
            _swapRouter.WETH()
        );
        _hearnBusdPair = IUniswapV2Factory(_swapRouter.factory()).createPair(
            address(this),
            BUSD
        );

        _isExcludedFromFee[_msgSender()] = true;
        _isExcludedFromFee[DEAD] = true;
        _isExcludedFromFee[ZERO] = true;
        _isExcludedFromFee[address(this)] = true;

        _isExcludedFromAntiBot[_msgSender()] = true;
        _isExcludedFromAntiBot[DEAD] = true;
        _isExcludedFromAntiBot[ZERO] = true;
        _isExcludedFromAntiBot[address(this)] = true;
        _isExcludedFromAntiBot[address(_swapRouter)] = true;
        _isExcludedFromAntiBot[address(_hearnBnbPair)] = true;
        _isExcludedFromAntiBot[address(_hearnBusdPair)] = true;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing
     * the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token operator
     */
    function mint(address to, uint256 amount)
        external
        onlyOperator
        returns (bool)
    {
        _mint(to, amount);
        return true;
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `msg.sender`, increasing
     * the total supply.
     *
     * Requirements
     *
     * - `msg.sender` must be the token operator
     */
    function mint(uint256 amount) external onlyOperator returns (bool) {
        _mint(_msgSender(), amount);
        return true;
    }

    function operator() public view virtual returns (address) {
        return _operator;
    }

    function transferOperator(address newOperator) public virtual onlyOperator {
        require(
            newOperator != address(0),
            "HEARN: new operator is the zero address"
        );
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
        // Exclude new operator from anti bot and fee
        _isExcludedFromAntiBot[_operator] = true;
        _isExcludedFromFee[_operator] = true;
    }

    function excludeFromFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = true;
    }

    function includeInFee(address account) external onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function excludeFromAntiBot(address account) external onlyOwner {
        _isExcludedFromAntiBot[account] = true;
    }

    function includeInAntiBot(address account) external onlyOwner {
        _isExcludedFromAntiBot[account] = false;
    }

    function setAntiBotConfiguration(
        uint256 maxTxAmount,
        uint256 maxWalletAmount
    ) external onlyOwner {
        require(
            maxTxAmount >= MAX_TX_AMOUNT_MIN_LIMIT,
            "Max tx amount too small"
        );
        require(
            maxWalletAmount >= MAX_WALLET_AMOUNT_MIN_LIMIT,
            "Max wallet amount too small"
        );
        _maxTxAmount = maxTxAmount;
        _maxWalletAmount = maxWalletAmount;
    }

    function setAllFeePercent(uint16 liquidityFee, uint16 marketingFee)
        external
        onlyOwner
    {
        require(liquidityFee <= MaxLiqFee, "Liquidity fee overflow");
        require(marketingFee <= MaxMarketingFee, "Buyback fee overflow");
        _liquidityFee = liquidityFee;
        _marketingFee = marketingFee;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        _swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setMarketingWallet(address newMarketingWallet) external onlyOwner {
        require(newMarketingWallet != address(0), "ZERO ADDRESS");
        _marketingWallet = newMarketingWallet;
    }

    function setLiquidifyHelper(LiquidifyHelper newLiquidifyHelper)
        external
        onlyOwner
    {
        require(
            address(newLiquidifyHelper) != address(0),
            "Invalid liquidify helper"
        );

        // Include old liquidify helper into anti bot
        if (address(_liquidifyHelper) != address(0)) {
            _isExcludedFromAntiBot[address(_liquidifyHelper)] = false;
        }
        _liquidifyHelper = newLiquidifyHelper;
        // Exclude new liquidify helper from anti bot
        _isExcludedFromAntiBot[address(_liquidifyHelper)] = true;
    }

    function setSwapRouter(address newSwapRouter) external onlyOwner {
        require(newSwapRouter != address(0), "Invalid swap router");

        // Include old router and pairs into anti bot
        _isExcludedFromAntiBot[address(_swapRouter)] = false;
        _isExcludedFromAntiBot[address(_hearnBnbPair)] = false;
        _isExcludedFromAntiBot[address(_hearnBusdPair)] = false;

        _swapRouter = IUniswapV2Router02(newSwapRouter);
        _liquidifyHelper.setSwapRouter(newSwapRouter);

        // Create a uniswap pair for this new token
        _hearnBnbPair = IUniswapV2Factory(_swapRouter.factory()).createPair(
            address(this),
            _swapRouter.WETH()
        );
        _hearnBusdPair = IUniswapV2Factory(_swapRouter.factory()).createPair(
            address(this),
            BUSD
        );

        // Exclude new router and pairs from anti bot
        _isExcludedFromAntiBot[address(_swapRouter)] = false;
        _isExcludedFromAntiBot[address(_hearnBnbPair)] = false;
        _isExcludedFromAntiBot[address(_hearnBusdPair)] = false;
    }

    function setNumTokensSellToAddToLiquidity(
        uint256 numTokensSellToAddToLiquidity
    ) external onlyOwner {
        require(numTokensSellToAddToLiquidity > 0, "Invalid input");
        _numTokensSellToAddToLiquidity = numTokensSellToAddToLiquidity;
    }

    //to recieve ETH from swapRouter when swaping
    receive() external payable {}

    function isExcludedFromFee(address account) external view returns (bool) {
        return _isExcludedFromFee[account];
    }

    function isExcludedFromAntiBot(address account)
        external
        view
        returns (bool)
    {
        return _isExcludedFromAntiBot[account];
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");
        require(amount > 0, "Transfer amount must be greater than zero");

        if (!_isExcludedFromAntiBot[from]) {
            require(amount <= _maxTxAmount, "Too many tokens are going to transferred");
        }
        if (!_isExcludedFromAntiBot[to]) {
            require(balanceOf(to).add(amount) <= _maxWalletAmount, "Too many tokens are going to be stored in target account");
        }

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is uniswap pair.
        uint256 contractTokenBalance = balanceOf(address(this));
        bool tokenBeingSold = to == _hearnBnbPair || to == _hearnBusdPair;

        if (!_inSwapAndLiquify && tokenBeingSold && _swapAndLiquifyEnabled) {
            if (contractTokenBalance >= _numTokensSellToAddToLiquidity) {
                contractTokenBalance = _numTokensSellToAddToLiquidity;
                // add liquidity, send to marketing wallet
                swapAndLiquify(contractTokenBalance);
            }
        }

        // indicates if fee should be deducted from transfer
        // if any account belongs to _isExcludedFromFee account then remove the fee
        bool takeFee = !_isExcludedFromFee[from] &&
            !_isExcludedFromFee[to] &&
            tokenBeingSold;

        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from, to, amount, takeFee);
    }

    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        //This needs to be distributed among marketing wallet and liquidity
        if (_liquidityFee == 0 && _marketingFee == 0) {
            return;
        }

        uint256 marketingBalance = contractTokenBalance.mul(_marketingFee).div(
            uint256(_marketingFee).add(_liquidityFee)
        );
        if (marketingBalance > 0) {
            contractTokenBalance = contractTokenBalance.sub(marketingBalance);
            uint256 busdAmount = swapTokensForBusd(
                marketingBalance,
                _marketingWallet
            );
            emit MarketingFeeTrasferred(
                _marketingWallet,
                marketingBalance,
                busdAmount
            );
        }

        if (contractTokenBalance > 0) {
            // split the contract balance into halves
            uint256 half = contractTokenBalance.div(2);
            uint256 otherHalf = contractTokenBalance.sub(half);

            // tokens and busd are sent to liquidify helper contract and added to liquidity to be burned
            super._transfer(
                address(this),
                address(_liquidifyHelper),
                otherHalf
            );
            // swap tokens for BUSD
            uint256 busdAmount = swapTokensForBusd(
                half,
                address(_liquidifyHelper)
            );

            // add liquidity to pancakeswap
            if (otherHalf > 0 && busdAmount > 0) {
                _liquidifyHelper.liquifyAndBurn();
                emit LiquifyAndBurned(half, busdAmount, otherHalf);
            }
        }
    }

    function swapTokensForBusd(uint256 tokenAmount, address to)
        private
        returns (uint256 busdAmount)
    {
        // generate the uniswap pair path of token -> busd
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = BUSD;

        _approve(address(this), address(_swapRouter), tokenAmount);

        // capture the contract's current BUSD balance.
        // this is so that we can capture exactly the amount of BUSD that the
        // swap creates, and not make the liquidity event include any BUSD that
        // has been manually sent to the contract
        uint256 balanceBefore = IERC20(BUSD).balanceOf(to);

        // make the swap
        _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BUSD
            path,
            to,
            block.timestamp.add(300)
        );

        // how much BUSD did we just swap into?
        busdAmount = IERC20(BUSD).balanceOf(to).sub(balanceBefore);
    }

    function addLiquidityAndBurn(uint256 tokenAmount, uint256 busdAmount)
        private
    {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_swapRouter), tokenAmount);
        IERC20(BUSD).approve(address(_swapRouter), busdAmount);

        // add the liquidity
        _swapRouter.addLiquidity(
            address(this),
            BUSD,
            tokenAmount,
            busdAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            DEAD,
            block.timestamp.add(300)
        );
    }

    //this method is responsible for taking all fee, if takeFee is true
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bool takeFee
    ) private {
        if (takeFee) {
            uint256 feeAmount = amount
                .mul(uint256(_liquidityFee).add(_marketingFee))
                .div(10000);
            if (feeAmount > 0) {
                super._transfer(sender, address(this), feeAmount);
                amount = amount.sub(feeAmount);
            }
        }
        if (amount > 0) {
            super._transfer(sender, recipient, amount);
        }
    }

    function recoverToken(address tokenAddress, uint256 tokenAmount)
        public
        onlyOwner
    {
        // do not allow recovering self token
        require(tokenAddress != address(this), "Self withdraw");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
    }
}
