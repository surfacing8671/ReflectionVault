pragma solidity ^0.8.0;

import "../lib/token/ERC20/ERC20.sol";
import "../lib/token/ERC20/IERC20.sol";
import "../lib/utils/math/SafeMath.sol";
import "../lib/access/Ownable.sol";
import "../lib/security/ReentrancyGuard.sol";
import "../lib/security/Pausable.sol";
import "../lib/token/ERC20/utils/SafeERC20.sol";


import "../interfaces/IUniswapV2RouterLean.sol";
import "../interfaces/IVaultLean.sol";
import "../interfaces/IMigrator.sol";
import "../interfaces/IERC20Burnable.sol";



contract ScytheLock is ERC20,Ownable,Pausable,ReentrancyGuard{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IVaultLean;

    /*
        fees delegated in 0.01% increments
    */
    uint256 public reflection = 500;           // 5%
    uint256 public reflectionTransfer = 500;   // 5%
    uint256 public buyback = 50;               // 0.5%
    IERC20Burnable public scytheToken;          // scythe token

    IERC20 public want;                         // token wanted by the vault
    address public wantAddress;
    IUniswapV2RouterLean public router;
    IUniswapV2RouterLean public buyBackRouter;  // this can be a normal router (for buyback & burn) or a liquidity router (for buying up liquidity)
    IVaultLean public vault;                    // vault that is target of the lock, this can 
    bool public ETHEnabled = true;
    address public delegatedBuyback;

    event BuyBack(uint256 shares,bool direct);
    event Withdraw(uint256 shares, uint256 fee);

    constructor(string memory name, string memory symbol,address _want, IUniswapV2RouterLean _router,IVaultLean _vault, IERC20Burnable _scytheToken) ERC20(name, symbol) {
        wantAddress = _want;
        want = IERC20(_want);
        router = _router;
        buyBackRouter = _router;
        vault = _vault;
        scytheToken = _scytheToken;
        delegatedBuyback = msg.sender;
    }

    function changeRouter(IUniswapV2RouterLean _router) external onlyOwner {
        router = _router;
    }
    function changebuyBackRouter(IUniswapV2RouterLean _router) external onlyOwner {
        buyBackRouter = _router;
    }
    function setDelegate(address _delegatedBuyback) external onlyOwner {
        delegatedBuyback = _delegatedBuyback;
    }
    
    function changeFees(uint _reflection, uint _reflectionTransfer, uint _buyback) external onlyOwner{

        require(_reflection<=2000,"reflexion may not be greater than 20%");
        require(_reflectionTransfer<=2000,"reflexion on transfer may not be greater than 20%");
        require(_buyback<=1,"buyback may not be greater than 1%");

        reflection = _reflection;
        reflectionTransfer = _reflectionTransfer;
        buyback = _buyback;
    }

    function getBuyBackShares() external view returns(uint){
        return IERC20(this).balanceOf(address(this));
    }

    function handleBuyBack(uint256 _amount, uint256 _amountOutMin) external onlyOwner {
        uint amount = _amount;

        // transfer to owner without any fees as they will be paid on withdrawl
        _transfer(address(this), owner(), amount);

        

        //withdraw to ETH
        uint256 withdrawn = withdraw(amount,address(this));
        uint256 deltaBalance = want.balanceOf(address(this));
        vault.withdraw(withdrawn);
        deltaBalance = want.balanceOf(address(this)).sub(deltaBalance);

        want.safeApprove(address(buyBackRouter), deltaBalance);

        address[] memory path = new address[](3);
        path[0] = wantAddress;
        path[1] = buyBackRouter.WETH();
        path[2] = address(scytheToken);
        buyBackRouter.swapExactTokensForTokens(
            deltaBalance,
            _amountOutMin,
            path,
            address(this),
            block.timestamp
        );
        scytheToken.burn(scytheToken.balanceOf(address(this)));
        emit BuyBack(amount, false);
        //_burn(address(this),scytheToken.balanceOf(address(this)));
    }

    function handleBuyBackDirect(uint256 _amount) external onlyOwner {

         uint amount = _amount;

        _transfer(address(this), owner(), amount);

        uint256 withdrawn = withdraw(amount,address(this));
        uint256 deltaBalance = want.balanceOf(address(this));
        vault.withdraw(withdrawn);
        deltaBalance = want.balanceOf(address(this)).sub(deltaBalance);

        want.transfer(address(delegatedBuyback), deltaBalance);
        
        emit BuyBack(amount, true);

    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
    function migrate(IMigrator migrator,address _want, IVaultLean _vault,uint _minAmmt) external onlyOwner {
        // allow migrator to use all of vault in migration
        vault.safeApprove(address(migrator),vault.balanceOf(address(this)));

        // migrator 
        migrator.migrate(_minAmmt);
        wantAddress = _want;
        want = IERC20(_want);
        vault = _vault;

        // migration can take a while, pause deposits and withdrawls
        _pause();
    }

    /*
        this is in case tokens get stuck inside the contract. this cannot be used to withdraw any vault tokens from the users
    */
    function emergencyExit(address token,uint ammt) external onlyOwner {
        require(token!=address(vault),"emergency exit can NOT be used for the vault token");
        IERC20(token).safeTransfer(owner(),ammt);
    }


    function depositAll() external {
        deposit(vault.balanceOf(msg.sender),msg.sender);
    }
    
    // Enter the bar. Pay some vaults. Earn some shares.

    function deposit(uint256 _amount,address _to) public whenNotPaused {
        uint256 totalvault = vault.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        uint256 what = _amount;
        if( totalShares != 0 && totalvault != 0){
            what = _amount.mul(totalShares).div(totalvault);
        }

        uint256 fees = what.mul(buyback).div(10000);
        _mint(address(this), fees);
        _mint(_to, what.sub(fees));
        vault.safeTransferFrom(msg.sender, address(this), _amount);
    }
    function balance() public view returns(uint256){
        return vault.balanceOf(address(this));
    }

    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
    }
    function withdrawAll(address _to) external {
        withdraw(balanceOf(msg.sender),_to);
    }
    
    // Leave the lock. Claim back your vaults. (this essentially burns a fee in shares then withdraws as normal)
    function withdraw(uint256 _share, address _to) public whenNotPaused returns(uint256 what) {

        uint fees = _share.mul(reflection).div(10000);
        uint256 totalShares = totalSupply().sub(fees);

        what = _share.sub(fees).mul(vault.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);

        vault.safeTransfer(_to, what);
        
        emit Withdraw(_share, fees);
    }

    function setEthEnabled(bool _ETHEnabled) external onlyOwner{
        ETHEnabled = _ETHEnabled;
    }


    function withdrawETH(uint256 _share,uint256 _amountOutMin,address _to) external nonReentrant {
        require(ETHEnabled,"ETH deposits/withdrawls have been temporarily suspended");

        uint256 withdrawn = withdraw(_share,address(this));
        uint256 deltaBalance = want.balanceOf(address(this));
        vault.withdraw(withdrawn);
        deltaBalance = want.balanceOf(address(this)).sub(deltaBalance);

        want.safeApprove(address(router), deltaBalance);

        address[] memory path = new address[](2);
        path[0] = wantAddress;
        path[1] = router.WETH();
        router.swapExactTokensForETH(
            deltaBalance,
            _amountOutMin,
            path,
            _to,
            block.timestamp
        );

    }

    function estTokensFromShare(uint256 _share) public view returns(uint256 what) {
        uint fees = _share.mul(reflection).div(10000);
        uint256 totalShares = totalSupply().sub(fees);
        what = _share.sub(fees).mul(vault.balanceOf(address(this))).div(totalShares);
    }
    
    



    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        uint fees = amount.mul(reflectionTransfer).div(10000);
        _burn(owner,fees);
        _transfer(owner, to, amount.sub(fees));
        return true;
    }
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        uint fees = amount.mul(reflectionTransfer).div(10000);
        _burn(from,fees);
        _transfer(from, to, amount.sub(fees));
        return true;
    }

}