pragma solidity ^0.8.0;

import "../lib/token/ERC20/ERC20.sol";
import "../lib/token/ERC20/IERC20.sol";
import "../lib/utils/math/SafeMath.sol";
import "../lib/access/Ownable.sol";
import "../lib/security/ReentrancyGuard.sol";
import "../lib/security/Pausable.sol";
import "../lib/token/ERC20/utils/SafeERC20.sol";
import "../hardhat/ console.sol";

import "../interfaces/IUniswapV2RouterLean.sol";
import "../interfaces/IVaultLean.sol";
import "../interfaces/IMigrator.sol";
import "../interfaces/IERC20Burnable.sol";
//import "./interfaces/IBeefyZap.sol";

import "./LockedVault.sol";



contract ScytheEnter is Ownable,ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IVaultLean;

    IUniswapV2RouterLean public router;     // router for swap
    ScytheLock public scytheLock;           // scythelock vault
    IVaultLean public vault;
    IERC20 public want;
    IERC20 public scytheToken;
    address[] public route;
    address[] public route2;
    uint constant internal UINT_MAX = ~uint(0);
    uint256 public immutable halving;
    // emits 0.0001*vault 


    constructor(IUniswapV2RouterLean _router,ScytheLock _scytheLock,IERC20 _scytheToken,uint256 _halving) {
        router = _router;
        scytheLock = _scytheLock;
        scytheToken = _scytheToken;
        vault = scytheLock.vault();
        want = scytheLock.want();
        want.safeApprove(address(vault), UINT_MAX);
        vault.safeApprove(address(scytheLock), UINT_MAX);
        want.safeApprove(address(router), UINT_MAX);

        route = new address[](2);
        route[0] = router.WETH();
        route[1] = address(want);

        route2 = new address[](2);
        route2[0] = address(want);
        route2[1] = router.WETH();
        
        halving = _halving;
    }

    /*
        if this entry contract is decomissioned
    */
    function withdrawScythe() external onlyOwner {
        scytheToken.transfer(msg.sender, scytheToken.balanceOf(address(this)));
    }

    function changeRouter(IUniswapV2RouterLean _router) external onlyOwner {
        router = _router;
        route = new address[](2);
        route[0] = router.WETH();
        route[1] = address(want);

        route2 = new address[](2);
        route2[0] = address(want);
        route2[1] = router.WETH();
    }
    function getDecay(uint256 value, uint256 t, uint256 halfLife) public pure returns (uint256 decayed) {
        value >>= (t / halfLife);
        t %= halfLife;
        decayed = value - value * t / halfLife / 2;
    }
    function getScytheRewards(uint256 _deposit) public view returns(uint256 scythe){

        scythe= scytheToken.balanceOf(address(this));

        scythe = scythe.sub(getDecay(scythe,_deposit,halving));
    }
    /*
        claim SCYTHE rewards based on the amount of vault tokens deposited
    */
    function claimScythe(uint256 _amount,address _to) private {
        scytheToken.transfer(_to,getScytheRewards(_amount));
    }

    
    function depositETH(uint256 _amountOutMin, address _to) external payable nonReentrant {
        uint[] memory amounts = router.swapExactETHForTokens{value:msg.value}(
            _amountOutMin,
            route,
            address(this),
            block.timestamp
        );
        // now we have want 
        vault.deposit(amounts[1]);

        uint256 vb = vault.balanceOf(address(this));
        claimScythe(vb, _to);
        scytheLock.deposit(vb,_to);
    }

    function estimateSwap(uint256 _amount) public view returns(uint256){
        uint[] memory amounts = router.getAmountsOut(_amount, route);
        return amounts[1];
    }

    function estimateDepositETH(uint256 _amount) external view returns(uint256){
        return estimateDepositWant(estimateSwap(_amount));
    }
    function estimateDepositWant(uint256 _amount) public view returns(uint256){

        uint256 estimate = ((_amount*1e18)/vault.getPricePerFullShare());
        uint256 fees = estimate*scytheLock.buyback()/10000;
        
        return 1e18*(estimate-fees)/scytheLock.getPricePerFullShare();
    }

    function estimateDepositWantScythe(uint256 _amount) public view returns(uint256){
        return getScytheRewards(((_amount*1e18)/vault.getPricePerFullShare()));
    }


    function estimateDepositETHScythe(uint256 _amount) public view returns(uint256){
        return estimateDepositWantScythe(estimateSwap(_amount));
    }

    function depositWant(uint256 _amount, address _to) external nonReentrant {
        want.transferFrom(msg.sender,address(this),_amount);
        vault.deposit(_amount);
        uint256 vb = vault.balanceOf(address(this));
        claimScythe(vb, _to);
        scytheLock.deposit(vb,_to);
    }

   /* function depositWithBeefy(address beefyZap, address beefyVault, uint256 tokenAmountOutMin, address tokenIn, uint256 tokenInAmount,address _to) external nonReentrant {
        IBeefyZap zap = IBeefyZap(beefyZap);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), tokenInAmount);

        IERC20(tokenIn).approve(beefyZap,tokenInAmount);

        zap.beefIn(beefyVault, tokenAmountOutMin, tokenIn, tokenInAmount);

        uint amount = IERC20(beefyVault).balanceOf(address(this));

        claimScythe(amount, _to);
        scytheLock.deposit(amount,_to);
    }
*/


    function deposit(uint256 _amount, address _to) external nonReentrant {
        vault.transferFrom(msg.sender,address(this),_amount);
        claimScythe(_amount, _to);
        scytheLock.deposit(_amount,_to);
    }

    function estETHFromShare(uint256 _share) public view returns(uint256 what){
        uint[] memory amounts = router.getAmountsOut((scytheLock.estTokensFromShare(_share)*vault.getPricePerFullShare())/(1e18), route2);
        return amounts[1];
    }
    function estTokensFromShareLP(uint256 _share,address token1,address token2) public view returns(uint256 t1, uint256 t2){
        uint lpt = (scytheLock.estTokensFromShare(_share)*vault.getPricePerFullShare())/(1e18);
        t1 = IERC20(token1).balanceOf(address(vault.want()))*lpt/vault.want().totalSupply();
        t2 = IERC20(token2).balanceOf(address(vault.want()))*lpt/vault.want().totalSupply();
        // IERC20(token1).test();
    }
    


    function withdrawETH(uint256 _share,uint256 _amountOutMin,address _to) external nonReentrant {

        vault.transferFrom(msg.sender,address(this),_share);
        
        vault.withdraw(vault.balanceOf(address(this)));

        router.swapExactTokensForETH(
            scytheLock.want().balanceOf(address(this)),
            _amountOutMin,
            route2,
            _to,
            block.timestamp
        );

    }
}