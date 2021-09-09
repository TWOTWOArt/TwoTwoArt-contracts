// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;


import "./StrategyInterface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import "./SafeERC20.sol";

contract X22LP is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 constant public N_COINS=3;
    
    uint256 public constant DENOMINATOR = 10000;

    uint128 public fees = 700; // 7% of amount to withdraw

    uint256 public poolPart = 750 ; // 7.5% of total Liquidity will remain in the pool

    uint256 public selfBalance;

    IERC20[N_COINS] public tokens;

    IERC20 public XPTtoken;

    rStrategy public strategy;
    
    address public wallet;
    
    address public nominatedWallet;

    uint public YieldPoolBalance;
    uint public liquidityProvidersAPY;

    //storage for user related to supply and withdraw
    
    uint256 public lock_period = 1 minutes;

    struct depositDetails {
        uint index;
        uint amount;
        uint256 time;
        uint256 remAmt;
    }
    
    mapping(address => depositDetails[]) public amountSupplied;
    mapping(address => uint256) public requestedAmount;
    mapping(address => uint256) public requestedTime;
    mapping(address => uint256) public requestedIndex;
    
    
    uint256 public coolingPeriod = 86400;
    

    mapping(address => bool)public reserveRecipients;

    uint[N_COINS] public storedFees;
    
    //storage to store total loan given
    uint256 public loanGiven;
    
    uint public loanPart=2000;
    
  
    modifier onlyWallet(){
      require(wallet ==msg.sender, "NA");
      _;
    }
  
     modifier validAmount(uint amount){
      require(amount > 0 , "NV");
      _;
    }
    
    // EVENTS 
    event userSupplied(address user,uint amount,uint index);
    event userRecieved(address user,uint amount,uint index);
    event feesTransfered(address user,uint amount,uint index);
    event loanTransfered(address recipient,uint amount,uint index);
    event loanRepayed(uint amount,uint index);
    event yieldAdded(uint amount,uint index);
    event walletNominated(address newOwner);
    event walletChanged(address oldOwner, address newOwner);
    event requestedWithdraw(address user,uint amount,uint index);
    event WithdrawCancel(address user);
    event userClaimed(address user, uint amount, uint index, bool payingCharges);
   
    
    constructor(address[N_COINS] memory _tokens,address _XPTtoken,address _wallet) {
        require(_wallet != address(0), "Wallet address cannot be 0");
        for(uint8 i=0; i<N_COINS; i++) {
            tokens[i] = IERC20(_tokens[i]);
        }
        XPTtoken = IERC20(_XPTtoken);
        wallet=_wallet;
    }
    
    function nominateNewOwner(address _wallet) external onlyWallet {
        nominatedWallet = _wallet;
        emit walletNominated(_wallet);
    }

    function acceptOwnership() external {
        require(msg.sender == nominatedWallet, "You must be nominated before you can accept ownership");
        emit walletChanged(wallet, nominatedWallet);
        wallet = nominatedWallet;
        nominatedWallet = address(0);
    }


    /* INTERNAL FUNCTIONS */
   
    
    //For checking whether array contains any non zero elements or not.
    function checkValidArray(uint256[N_COINS] memory amounts)internal pure returns(bool){
        for(uint8 i=0;i<N_COINS;i++){
            if(amounts[i]>0){
                return true;
            }
        }
        return false;
    }

    // This function deposits the liquidity to yield generation pool using yield Strategy contract
    function _deposit(uint256[N_COINS] memory amounts) internal {
        strategy.deposit(amounts);
        uint decimal;
        for(uint8 i=0;i<N_COINS;i++){
            decimal=tokens[i].decimals();
            YieldPoolBalance =YieldPoolBalance.add(amounts[i].mul(10**18).div(10**decimal));
        }
    }
   

    //This function is used to updating the array of user's individual deposit , called when users withdraw/claim tokens.
    function updateLockedXPT(address recipient,uint256 amount) internal{
        for(uint8 j=0; j<amountSupplied[recipient].length; j++) {
            if(amountSupplied[recipient][j].remAmt > 0 && amount > 0 ) {
                if(amount >= amountSupplied[recipient][j].remAmt) {
                        amount = amount.sub( amountSupplied[recipient][j].remAmt);
                        amountSupplied[recipient][j].remAmt = 0;
                }
                else {
                        amountSupplied[recipient][j].remAmt =(amountSupplied[recipient][j].remAmt).sub(amount);
                        amount = 0;
                }
            }
        }
     }


    // this will withdraw Liquidity from yield genaration pool using yield Strategy
    function _withdraw(uint256[N_COINS] memory amounts) internal {
        strategy.withdraw(amounts);
        uint decimal;
        for(uint8 i=0;i<N_COINS;i++){
            decimal=tokens[i].decimals();
            YieldPoolBalance =YieldPoolBalance.sub(amounts[i].mul(10**18).div(10**decimal));
        }
    }
    
    //This function calculate XPT to be mint or burn
    //amount parameter is amount of token
    //_index can be 0/1/2 
    //0-DAI
    //1-USDC
    //2-USDT
    function calcXPTAmount(uint256 amount,uint _index) public view returns(uint256) {
        uint256 total = calculateTotalToken(true);
        uint256 decimal = 0;
        decimal=tokens[_index].decimals();
        amount=amount.mul(1e18).div(10**decimal);
        if(total==0){
            return amount;
        }
        else{
          return (amount.mul(XPTtoken.totalSupply()).div(total)); 
        }
    }



    //function to check available amount to withdraw for user
    function availableLiquidity(address addr, uint coin,bool _time) public view returns(uint256 token,uint256 XPT) {
        uint256 amount=0;
        for(uint8 j=0; j<amountSupplied[addr].length; j++) {
                if( (!_time || (block.timestamp - amountSupplied[addr][j].time)  > lock_period)&&amountSupplied[addr][j].remAmt >0)   {
                        amount =amount.add(amountSupplied[addr][j].remAmt);
                }
        }
        uint256 total=calculateTotalToken(true);
        uint256 decimal;
        decimal=tokens[coin].decimals();
        return ((amount.mul(total).mul(10**decimal).div(XPTtoken.totalSupply())).div(10**18),amount);
    }
    

    //calculated available total tokens in the pool by substracting withdrawal, reserve amount.
    //In case supply is true , it adds total loan given.
    function calculateTotalToken(bool _supply)public view returns(uint256){
        uint256 decimal;
        uint storedFeesTotal;
        for(uint8 i=0; i<N_COINS; i++) {
            decimal = tokens[i].decimals();
            storedFeesTotal=storedFeesTotal.add(storedFees[i].mul(1e18).div(10**decimal));
        } 
        if(_supply){
            return selfBalance.sub(storedFeesTotal).add(loanGiven);
        }
        else{
            return selfBalance.sub(storedFeesTotal);
        }
        
    }
    
    /* USER FUNCTIONS (exposed to frontend) */
   
    //For depositing liquidity to the pool.
    //_index will be 0/1/2     0-DAI , 1-USDC , 2-USDT
    function supply(uint256 amount,uint256 _index) external nonReentrant  validAmount(amount){
        uint decimal;
        uint256 mintAmount=calcXPTAmount(amount,_index);
        amountSupplied[msg.sender].push(depositDetails(_index,amount,block.timestamp,mintAmount));
        decimal=tokens[_index].decimals();
        selfBalance=selfBalance.add(amount.mul(10**18).div(10**decimal));
        tokens[_index].safeTransferFrom(msg.sender, address(this), amount);
        XPTtoken.mint(msg.sender, mintAmount);
        emit userSupplied(msg.sender, amount,_index);
    }

    
    //for withdrawing the liquidity
    //First Parameter is amount of XPT
    //Second is which token to be withdrawal with this XPT.
    function requestWithdrawWithXPT(uint256 amount,uint256 _index, bool payingCharges) external nonReentrant validAmount(amount){
        require(!reserveRecipients[msg.sender],"Claim first");
        require(XPTtoken.balanceOf(msg.sender) >= amount, "low XPT");
        uint256[N_COINS] memory amountWithdraw;
        if(payingCharges == true){
           uint256 total = calculateTotalToken(true);
           uint256 tokenAmount;
           tokenAmount=amount.mul(total).div(XPTtoken.totalSupply());
           uint decimal;
           decimal=tokens[_index].decimals();
           tokenAmount = tokenAmount.mul(10**decimal).div(10**18);
           for(uint8 i=0;i<N_COINS;i++){
              if(i==_index){
                  amountWithdraw[i] = tokenAmount;
              }
              else{
                  amountWithdraw[i] = 0;
              }
           }
            uint256 currentPoolAmount = getBalances(_index);
            if(tokenAmount>currentPoolAmount){
                _withdraw(amountWithdraw);
            }
           
           uint temp = (tokenAmount.mul(fees)).div(10000);
           selfBalance = selfBalance.sub((tokenAmount.sub(temp)).mul(1e18).div(10**decimal));
           tokens[_index].safeTransfer(msg.sender, tokenAmount.sub(temp));
           emit userRecieved(msg.sender,tokenAmount.sub(temp),_index);
           storedFees[_index] =storedFees[_index].add(temp);
           XPTtoken.burn(msg.sender, amount);
           updateLockedXPT(msg.sender,amount);
        }
        else{    
        requestedAmount[msg.sender] = amount;
        requestedTime[msg.sender] = block.timestamp;
        reserveRecipients[msg.sender] = true;
        requestedIndex[msg.sender] = _index;
        emit requestedWithdraw(msg.sender, amount, _index);
        }
        
    }

    function cancelWithdraw() external{
        require(reserveRecipients[msg.sender] == true, 'You did not request anything!');
        requestedAmount[msg.sender] = 0;
        requestedTime[msg.sender] = 0;
        reserveRecipients[msg.sender] =false;
        requestedIndex[msg.sender] = 5;
        emit WithdrawCancel(msg.sender);
    }
    
    //For claiming withdrawal after user added to the reserve recipient.
    function claimTokens(bool payingCharges) external  nonReentrant{
        require(reserveRecipients[msg.sender] , "request withdraw first");
        uint256 total = calculateTotalToken(true);
        uint256 _index = requestedIndex[msg.sender];
        uint256 tokenAmount;
        tokenAmount=requestedAmount[msg.sender].mul(total).div(XPTtoken.totalSupply());
        uint decimal;
        decimal=tokens[_index].decimals();
        tokenAmount = tokenAmount.mul(10**decimal).div(10**18);
        uint temp =0;
        if(payingCharges){
                temp = (tokenAmount.mul(fees)).div(10000);
        }
        else{
            require(requestedTime[msg.sender]+coolingPeriod <= block.timestamp, "You have to wait for 8 days after requesting for withdraw");
        }
        uint256[N_COINS] memory amountWithdraw;
        for(uint8 i=0;i<N_COINS;i++){
              if(i==_index){
                  amountWithdraw[i] = tokenAmount;
              }
              else{
                  amountWithdraw[i] = 0;
              }
           }
            uint256 currentPoolAmount = getBalances(_index);
            if(tokenAmount>currentPoolAmount){
                _withdraw(amountWithdraw);
            }
        selfBalance = selfBalance.sub((tokenAmount.sub(temp)).mul(1e18).div(10**decimal));
        tokens[_index].safeTransfer(msg.sender, tokenAmount.sub(temp));
        emit userClaimed(msg.sender,tokenAmount.sub(temp),_index,payingCharges);
        storedFees[_index] =storedFees[_index].add(temp);
        XPTtoken.burn(msg.sender, requestedAmount[msg.sender]);
        updateLockedXPT(msg.sender,requestedAmount[msg.sender]);
        requestedAmount[msg.sender] = 0;
        reserveRecipients[msg.sender] = false;
        requestedIndex[msg.sender] = 5;
        requestedTime[msg.sender] = 0;
    }

    // this function deposits without minting XPT.
    //Used to deposit Yield
    function depositYield(uint256 amount,uint _index) external{
        uint decimal;
        decimal=tokens[_index].decimals();
        selfBalance=selfBalance.add(amount.mul(1e18).div(10**decimal));
        liquidityProvidersAPY=liquidityProvidersAPY.add(amount.mul(1e18).div(10**decimal));
        tokens[_index].safeTransferFrom(msg.sender,address(this),amount);
        emit yieldAdded(amount,_index);
    }


    /* CORE FUNCTIONS (called by owner only) */

    //Transfer token z`1   o rStrategy by maintaining pool ratio.
    function deposit() onlyWallet() external  {
        uint256[N_COINS] memory amounts;
        uint256 totalAmount;
        uint256 decimal;
        totalAmount=calculateTotalToken(false);
        uint balanceAmount=totalAmount.mul(poolPart).div(N_COINS).div(DENOMINATOR);
        uint tokenBalance;
        for(uint8 i=0;i<N_COINS;i++){
            decimal=tokens[i].decimals();
            amounts[i]=getBalances(i);
            tokenBalance=balanceAmount.mul(10**decimal).div(10**18);
            if(amounts[i]>tokenBalance) {
                amounts[i]=amounts[i].sub(tokenBalance);
                tokens[i].safeTransfer(address(strategy),amounts[i]);
            }
            else{
                amounts[i]=0;
            }
        }
        if(checkValidArray(amounts)){
            _deposit(amounts);
        }
    }
    

  //Withdraw total liquidity from yield generation pool
    function withdrawAll() external onlyWallet() {
        uint[N_COINS] memory amounts;
        amounts=strategy.withdrawAll();
        uint decimal;
        selfBalance=0;
        for(uint8 i=0;i<N_COINS;i++){
            decimal=tokens[i].decimals();
            selfBalance=selfBalance.add((tokens[i].balanceOf(address(this))).mul(1e18).div(10**decimal));
        }
        YieldPoolBalance=0;
    }


    //function for withdraw and  rebalancing royale pool(ratio)       
    function rebalance() onlyWallet() external {
        uint256 currentAmount;
        uint256[N_COINS] memory amountToWithdraw;
        uint256[N_COINS] memory amountToDeposit;
        uint totalAmount;
        uint256 decimal;
        totalAmount=calculateTotalToken(false);
        uint balanceAmount=totalAmount.mul(poolPart).div(N_COINS).div(DENOMINATOR);
        uint tokenBalance;
        for(uint8 i=0;i<N_COINS;i++) {
          currentAmount=getBalances(i);
          decimal=tokens[i].decimals();
          tokenBalance=balanceAmount.mul(10**decimal).div(10**18);
          if(tokenBalance > currentAmount) {
              amountToWithdraw[i] = tokenBalance.sub(currentAmount);
          }
          else if(tokenBalance < currentAmount) {
              amountToDeposit[i] = currentAmount.sub(tokenBalance);
              tokens[i].safeTransfer(address(strategy), amountToDeposit[i]);
               
          }
          else {
              amountToWithdraw[i] = 0;
              amountToDeposit[i] = 0;
          }
        }
        if(checkValidArray(amountToDeposit)){
             _deposit(amountToDeposit);
             
        }
        if(checkValidArray(amountToWithdraw)) {
            _withdraw(amountToWithdraw);
            
        }

    }
    
    //For withdrawing loan from the royale Pool
    function withdrawLoan(uint[N_COINS] memory amounts,address _recipient)external onlyWallet(){
        require(checkValidArray(amounts),"amount can not zero");
        uint decimal;
        uint total;
        for(uint i=0;i<N_COINS;i++){
          decimal=tokens[i].decimals();
          total=total.add(amounts[i].mul(1e18).div(10**decimal));
        }
        require(loanGiven.add(total)<=(calculateTotalToken(true).mul(loanPart).div(DENOMINATOR)),"Exceed limit");
        require(total<calculateTotalToken(false),"Not enough balance");
        bool strategyWithdraw=false;
        for(uint i=0;i<N_COINS;i++){
            if(amounts[i]>getBalances(i)){
                strategyWithdraw=true;
                break;
            }
        }
        if(strategyWithdraw){
          _withdraw(amounts); 
        }
        loanGiven =loanGiven.add(total);
        selfBalance=selfBalance.sub(total);
        for(uint8 i=0; i<N_COINS; i++) {
            if(amounts[i] > 0) {
                tokens[i].safeTransfer(_recipient, amounts[i]);
                emit loanTransfered(_recipient,amounts[i],i);
            }
        }
        
    }
    
  // For repaying the loan to the royale Pool.
    function repayLoan(uint[N_COINS] memory amounts)external {
        require(checkValidArray(amounts),"amount can't be zero");
        uint decimal;
        for(uint8 i=0; i<N_COINS; i++) {
            if(amounts[i] > 0) {
                decimal=tokens[i].decimals();
                loanGiven =loanGiven.sub(amounts[i].mul(1e18).div(10**decimal));
                selfBalance=selfBalance.add(amounts[i].mul(1e18).div(10**decimal));
                tokens[i].safeTransferFrom(msg.sender,address(this),amounts[i]);
                emit loanRepayed(amounts[i],i);
            }
        }
    }

    
    function claimFees() external nonReentrant{
        uint decimal;
        for(uint i=0;i<N_COINS;i++){
            if(storedFees[i] > 0){
            decimal=tokens[i].decimals();
            selfBalance = selfBalance.sub(storedFees[i].mul(1e18).div(10**decimal));
            tokens[i].safeTransfer(wallet,storedFees[i]);
            emit feesTransfered(wallet,storedFees[i],i);
            storedFees[i]=0;
            }
        }
    }
    

    //for changing pool ratio
    function changePoolPart(uint128 _newPoolPart) external onlyWallet()  {
        require(_newPoolPart < DENOMINATOR, "Entered pool part too high");
        poolPart = _newPoolPart;
        
    }

   //For changing yield Strategy
    function changeStrategy(address _strategy) onlyWallet() external  {
        require(YieldPoolBalance==0, "Call withdrawAll function first");
        strategy=rStrategy(_strategy);
        
    }

    function setLockPeriod(uint256 lockperiod) onlyWallet() external  {
        lock_period = lockperiod;
        
    }

     // for changing withdrawal fees  
    function setWithdrawFees(uint128 _fees) onlyWallet() external {
        require(_fees<100, "Entered fees too high");
        fees = _fees;

    }
    
    function setCoolingPeriod(uint128 _period) onlyWallet() external {
        coolingPeriod = _period; //in seconds

    }
    
    function changeLoanPart(uint256 _value)onlyWallet() external{
        require(_value < DENOMINATOR, "Entered loanPart too high");
        loanPart=_value;
    } 
    
    function getBalances(uint _index) public view returns(uint256) {
        return (tokens[_index].balanceOf(address(this)).sub(storedFees[_index]));
    }
}
