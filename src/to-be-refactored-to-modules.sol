// SPDX-License-Identifier: MIT 

pragma solidity ^0.8.7;

import '@openzeppelin/contracts/access/AccessControl.sol';
//import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '../contracts/dependencies/ISwapRouter.sol';
import '../contracts/dependencies/TransferHelper.sol';

contract VFPool is AccessControl{

    //------ access setup
	bytes32 public constant PROVIDER_ROLE = keccak256("Provider");

	// swapping
    ISwapRouter private swapRouter;
	uint24 private constant poolFee = 3000;

    uint256 public callbackPrice = 0;

	// Rinkeby:
    address private constant stable = 0x5592EC0cfb4dbc12D3aB100b257153436a1f0FEa; //dai
    address private constant volat = 0xc778417E063141139Fce010982780140Aa0cD5Ab; //weth

    address private constant DAIRopsten = 0xaD6D458402F60fD3Bd25163575031ACDce07538D;
    address private constant WETH9Ropsten = 0xc778417E063141139Fce010982780140Aa0cD5Ab;

    string public lastAdvice = ""; 
	
	//------ oracle request setup
	Request[] requests;
	uint256 currentId;
	struct Request{
		uint256 id;
		string tknPair;
		uint256 agreedValue;
	}
	
	event requestData(
		uint256 id,
		string tknPair
	);
	
	event requestDone(
		uint256 id,
		uint256 agreedValue
	);

    //------ trading setup
    //Array of prices: volatile coin - stable coin
    uint256[] prices;

    //algo parameters, these can be fine tuned

    //number of price values to determine average from
    uint256 lastXPrices = 10;
	
	//teiler des gesamten Token kapitals, das bei einem trade geswappt werden soll
	uint256 div = 4;

    //minimum numer of price values to determine average from
    uint256 minPrices = 6;

    //comparisson parameters
    // ANPASSEN!!
    uint256 minDifferenceUp = 5;
    uint256 minDifferenceDown = 5;
	
	//------ basic address setup
	constructor() {
	
		currentId = 0;
        
        swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // Rinkeby and ropsten
        
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(PROVIDER_ROLE, DEFAULT_ADMIN_ROLE);
        
    }

//-----------------------------
// Access control

	modifier onlyAdmin()
    {
        require(isAdmin(msg.sender), "Restricted to admins!");   
        _;
    }

    modifier onlyProvider()
    {
        require(isProvider(msg.sender), "Restricted to user!");
        _;
    }
    
    function isAdmin(address toTest) public view returns(bool)
    {
        return hasRole(DEFAULT_ADMIN_ROLE, toTest);
    }
    
    function isProvider(address toTest) public view returns(bool)
    {
        return hasRole(PROVIDER_ROLE, toTest);
    }
    
    function addProvider(address toAdd) public onlyAdmin
    {
        grantRole(PROVIDER_ROLE, toAdd);
    }
    
    function addAdmin(address toAdd) public onlyAdmin
    {
        grantRole(DEFAULT_ADMIN_ROLE, toAdd);
    }
    
    function removeProvider(address toRemove) public onlyAdmin
    {
        revokeRole(PROVIDER_ROLE, toRemove);
    }
    
    function removeAdmin(address toRemove) public onlyAdmin
    {
        revokeRole(DEFAULT_ADMIN_ROLE, toRemove);
    }
	
//-----------------------------
// Oracle functions

	function execRequest(
		string memory _tknPair
	)
	public
	onlyProvider
	{
		requests.push(Request(currentId, _tknPair,0));
		
		emit requestData(
			currentId,
			_tknPair
		);
		
		currentId++;
	}
	
	function callback(
		uint256 _id,
		uint256 _value
	)
	public
	payable
	onlyProvider
	{
		Request storage currRequest = requests[_id];
		currRequest.agreedValue = _value;
		
        callbackPrice = _value;

        // check id before push
        prices.push(_value);

		emit requestDone(
			_id,
			_value
		);
	}

//-----------------------------
// Gettes functions / interaction

    function getPrice(address _token) public view returns(uint256)
    {
        return IERC20(_token).balanceOf(address(this));
    }

    function withdraw(address _receiver, address _token, uint256 _amount) public payable onlyProvider
    {
        IERC20(_token).transfer(_receiver, _amount);
    }

    function getLastAdvice() public view returns(string memory)
    {
        return lastAdvice;
    }

    function getPriceList() public view returns(uint[] memory)
    {
        return prices;
    }

    function getRequestPriceAtID(uint256 _id) public view returns(uint256)
    {
        return requests[_id].agreedValue;
    }

//-----------------------------
// Pool functions

	function swapExcactInToOut(
        uint256 amountIn, 
        address tokenIN, 
        address tokenOUT
        ) 
        public 
        onlyProvider
        returns (uint256 amountOut) {
    
        // Approve the router to spend DAI.
        TransferHelper.safeApprove(tokenIN, address(swapRouter), amountIn);

        // Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
        // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIN,
                tokenOut: tokenOUT,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        // The call to `exactInputSingle` executes the swap.
        amountOut = swapRouter.exactInputSingle(params);

    }

	function investmentStrat() public payable onlyProvider returns (
            bool startTransfer, 
            address tokenIN, 
            address tokenOUT, 
            uint256 amount)
        {
		
        startTransfer = false;

        lastAdvice = evaluateLatestMovement();

        bytes32 recom = keccak256(abi.encodePacked(evaluateLatestMovement()));

        //für aktuell erstmal: komplette kapital des einen token swappen
		if (recom == keccak256(abi.encodePacked("buy"))) {
			// verkaufe den stabilen Token und erhalte dafür den volatilen
			tokenIN = stable;
			tokenOUT = volat;

            if ( IERC20(tokenIN).balanceOf(address(this)) > 0) {
			    amount = IERC20(tokenIN).balanceOf(address(this));
                startTransfer = true;
            }
		
		} else if (recom == keccak256(abi.encodePacked("sell"))) {
			// verkauf den volatilen Token und erhalte dafür stable 
			tokenIN = volat;
			tokenOUT = stable;

            if (IERC20(tokenOUT).balanceOf(address(this)) > 0) {
			    amount = IERC20(tokenOUT).balanceOf(address(this));
                startTransfer = true;
            } 
        }			
		else if (recom == keccak256(abi.encodePacked("hold"))) {
			// setze den Bool auf False, damit kein Swap ausgeführt wird
			startTransfer = false;
        }
		
        return (startTransfer, tokenIN, tokenOUT, amount);
    }

    // To Be executed by BOT
    function executeCurrentInvestmentAdvices(
        //uint256 fee_for_api_call
        ) public onlyProvider{
        
		// neue Daten in Price-List schreiben
		execRequest("DAI/WETH");
        
        // Get values from investmentStrat
        (
            bool startTransfer, 
            address tokenIN, 
            address tokenOUT, 
            uint256 amount
            ) = investmentStrat();
        
        if (startTransfer == true) {
            swapExcactInToOut(
                amount,
                tokenIN, 
                tokenOUT
            );
        }
    }

//-----------------------------
// Trading - Strat
    /*
    Add new value to stored values.
    Execute trade evaluation.
    */   
	/*
	Wird nicht gebraucht. evaluateLatestMovement() wird direkt von investmentStrat aufgerufen
    function addMockValue() public returns (string memory){
        string memory recommendation;
        recommendation = evaluateLatestMovement();
        return recommendation;
    }
	*/

    function avg(uint[] memory numberArray) private pure returns (uint){
        uint sum = 0;
        for(uint i=0; i<numberArray.length; i++){
            sum += 1000*numberArray[i];
        }
        uint numAvg = sum/numberArray.length;
        numAvg = numAvg/1000;
        return numAvg;
    }

    function lastXValues(uint x, uint[] memory numberArray) private pure returns (uint[] memory){
        if(numberArray.length <= x){
            return numberArray;
        }else{
            uint[] memory lastValues = new uint[](x);
            uint iterator=0;
            for(uint i=numberArray.length - x; i<numberArray.length; i++){
                lastValues[iterator] = numberArray[i];
                iterator++;
            }
            return lastValues;
        }
    }

    function compareLatestPriceToRelevantValues()private view returns (uint, bool){
         uint[] memory relevantValues = lastXValues(lastXPrices, prices);
         //require(relevantValues.length >= minPrices, "Not enough data.");
         
         if (relevantValues.length >= minPrices) {
            uint latestPrice = prices[prices.length - 1];
            uint relevantAverage = avg(relevantValues);
            //actual comparisson here
            uint difference = 0;
            bool priceIsUp = false;
            if(latestPrice >= relevantAverage){
                difference = latestPrice - relevantAverage;
                priceIsUp = true;
            }else{
                difference = relevantAverage - latestPrice;
            }
            //return difference and price movement
            return (difference, priceIsUp);
         }

         return (0, false);
         
    }

    //returns string: buy/sell/hold
    function evaluateLatestMovement() private view returns (string memory){
        bool priceIsUp;
        uint difference;
        (difference, priceIsUp) =  compareLatestPriceToRelevantValues();
        if(priceIsUp){
            if(difference >= minDifferenceUp){
                //recommend sell
                return "sell";
            }else{
                //recommend hold
                return "hold";
            }
        }else{
            if(difference >= minDifferenceDown){
                //recommend buy
                return "buy";
            }else{
                //recommend hold
                return "hold";
            }
        }
    }

        // transferRewardsToExecutor();
}
