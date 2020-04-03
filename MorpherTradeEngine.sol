pragma solidity 0.5.16;

//import "../node_modules/@openzeppelin/contracts/ownership/Ownable.sol";
//import "../node_modules/@openzeppelin/contracts/math/SafeMath.sol";
import "./Ownable.sol";
import "./SafeMath.sol";
import "./MorpherState.sol";

// ----------------------------------------------------------------------------------
// Tradeengine of the Morpher platform
// Creates and processes orders, and computes the state change of portfolio.
// Needs writing/reading access to/from Morpher State. Order objects are stored locally,
// portfolios are stored in state.
// ----------------------------------------------------------------------------------

contract MorpherTradeEngine is Ownable {
    MorpherStateBeta state;
    using SafeMath for uint256;

// ----------------------------------------------------------------------------
// Precision of prices and leverage
// ----------------------------------------------------------------------------
    uint256 constant PRECISION = 10**8;
    uint256 maximumLeverage;
    uint256 orderNonce;
    bytes32 public lastOrderId;

// ----------------------------------------------------------------------------
// Order struct contains all order specific varibles. Variables are completed
// during processing of trade. State changes are saved in the order struct as
// well, since local variables would lead to stack to deep errors *sigh*.
// ----------------------------------------------------------------------------
    struct order {
        address userId;
        bool tradeAmountGivenInShares;
        bytes32 marketId;
        uint256 tradeAmount;
        bool tradeDirection;
        uint256 liquidationTimestamp;
        uint256 marketPrice;
        uint256 marketSpread;
        uint256 orderLeverage;
        uint256 timeStamp;
        uint256 longSharesOrder;
        uint256 shortSharesOrder;
        uint256 balanceDown;
        uint256 balanceUp;
        uint256 newLongShares;
        uint256 newShortShares;
        uint256 newMeanEntryPrice;
        uint256 newMeanEntrySpread;
        uint256 newMeanEntryLeverage;
        uint256 newLiquidationPrice;
    }

    mapping(bytes32 => order) orders;

// ----------------------------------------------------------------------------
// Events
// Order created/processed events are fired by MorpherOracle.
// ----------------------------------------------------------------------------

    event LongPositionLiquidated(
        address indexed _address,
        bytes32 indexed _marketId,
        uint256 _timeStamp,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _blockNumber,
        uint256 _blockTimeStamp
    );

    event ShortPositionLiquidated(
        address indexed _address,
        bytes32 indexed _marketId,
        uint256 _timeStamp,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _blockNumber,
        uint256 _blockTimeStamp
        );
        
    event CancelOrder(
        bytes32 indexed _orderId,
        address indexed _address,
        uint256 _blockNumber,
        uint256 _blockTimeStamp
        );

    constructor(address _stateAddress) public {
        setMorpherState(_stateAddress);
        maximumLeverage = 10;
    }

    modifier onlyGovernance {
        require(msg.sender == state.getGovernanceContract(), "Function can only be called by Governance Contract.");
        _;
    }

    modifier onlyOracle {
        require(msg.sender == state.getOracleContract(), "Function can only be called by Oracle Contract.");
        _;
    }

    modifier onlyAdministrator {
        require(msg.sender == state.getAdministrator(), "Function can only be called by the Administrator.");
        _;
    }

// ----------------------------------------------------------------------------
// Administrative functions
// Set state address and maximum permitted leverage on platform
// ----------------------------------------------------------------------------

    function setMorpherState(address _stateAddress) public onlyOwner returns (bool _success)  {
        state = MorpherStateBeta(_stateAddress);
        return true;
    }

    function setMaximumLeverage(uint256 _maximumLeverage) public onlyAdministrator returns(bool _success) {
        maximumLeverage = _maximumLeverage;
        return true;
    }

    function getMaximumLeverage() public view returns(uint256 _maximumLeverage) {
        return maximumLeverage;
    }

    function getLastOrderId() public view returns(bytes32 _lastOrderId) {
        return lastOrderId;
    }

// ----------------------------------------------------------------------------
// Record positions by market by address. Needed for exposure aggregations
// and spits and dividends.
// ----------------------------------------------------------------------------
/* CONTRACT TOO LARGE
    function addExposureByMarket(bytes32 _symbol, address _address) private returns (bool _success) {
        // Address must not be already recored
        uint256 _myExposureIndex = state.getExposureMappingIndex(_symbol, _address);
        if (_myExposureIndex == 0) {
            uint256 _maxMappingIndex = state.getMaxMappingIndex(_symbol).add(1);
            state.setMaxMappingIndex(_symbol, _maxMappingIndex);
            state.setExposureMapping(_symbol, _address, _maxMappingIndex);
            return true;
        } else {
            return false;
        }
    }

    function deleteExposureByMarket(bytes32 _symbol, address _address) private returns (bool _success) {
        // Get my index in mapping
        uint256 _myExposureIndex = state.getExposureMappingIndex(_symbol, _address);
        // Get last element of mapping
        uint256 _lastIndex = state.getMaxMappingIndex(_symbol);
        address _lastAddress = state.getExposureMappingAddress(_symbol, _lastIndex);
        // If _myExposureIndex is greater than 0 (i.e. there is an exposure of that address on that market) delete it
        if (_myExposureIndex > 0) {
        // If _myExposureIndex is less than _lastIndex overwrite element at _myExposureIndex with element at _lastIndex in
        // deleted elements position. 
            if (_myExposureIndex < _lastIndex) {
                state.setExposureMappingAddress(_symbol, _lastAddress, _myExposureIndex);
                state.setExposureMappingIndex(_symbol, _lastAddress, _myExposureIndex);
            } 
            // Delete _lastIndex and _lastAddress element and reduce maxExposureIndex
            state.setExposureMappingAddress(_symbol, address(0), _lastIndex);
            state.setExposureMappingIndex(_symbol, _address, 0);
            // Shouldn't happen, but check that not empty
            if (_lastIndex > 0) {
                state.setMaxMappingIndex(_symbol, _lastIndex.sub(1));
            }
        }
        return true;
    }

// ----------------------------------------------------------------------------
// Pass through Setter/Getter functions for market wise exposure in state.
// Oracle not authorized to read/write to/from state directly
// ----------------------------------------------------------------------------

    function getMaxMappingIndex(bytes32 _marketId) public view returns(uint256 _maxMappingIndex) {
        return state.getMaxMappingIndex(_marketId);
    }

    function getExposureMappingIndex(bytes32 _marketId, address _address) public view returns(uint256 _mappingIndex) {
        return state.getExposureMappingIndex(_marketId, _address);
    }

    function getExposureMappingAddress(bytes32 _marketId, uint256 _mappingIndex) public view returns(address _address) {
        return state.getExposureMappingAddress(_marketId, _mappingIndex);
    }

    function setMaxMappingIndex(bytes32 _marketId, uint256 _maxMappingIndex) public onlyOracle returns(bool _success) {
        state.setMaxMappingIndex(_marketId, _maxMappingIndex);
        return true;
    }

    function setExposureMapping(bytes32 _marketId, address _address, uint256 _index) public onlyOracle returns(bool _success) {
        state.setExposureMappingIndex(_marketId, _address, _index);
        state.setExposureMappingAddress(_marketId, _address, _index);
        return true;
    }

    function setExposureMappingIndex(bytes32 _marketId, address _address, uint256 _index) public onlyOracle returns(bool _success) {
        state.setExposureMappingIndex(_marketId, _address, _index);
        return true;
    }

    function setExposureMappingAddress(bytes32 _marketId, address _address, uint256 _index) public onlyOracle returns(bool _success) {
        state.setExposureMappingAddress(_marketId, _address, _index);
        return true;
    }
*/
// ----------------------------------------------------------------------------
// requestOrderId(address _address, bytes32 _marketId, bool _tradeAmountGivenInShares, uint256 _tradeAmount, bool _tradeDirection, uint256 _orderLeverage)
// Creates a new order object with unique orderId and assigns order information.
// Must be called by MorpherOracle contract.
// ----------------------------------------------------------------------------

    function requestOrderId(
        address _address,
        bytes32 _marketId,
        bool _tradeAmountGivenInShares,
        uint256 _tradeAmount,
        bool _tradeDirection,
        uint256 _orderLeverage
        ) public onlyOracle returns (bytes32 _orderId) {
        require(_orderLeverage >= PRECISION, "Leverage too small. Leverage precision is 1e8 - 1e9");
        require(PRECISION.mul(maximumLeverage) >= _orderLeverage, "Leverage exceeds maximum allowed leverage.");
        require(state.getMarketActive(_marketId) == true, "Market unknown or currently not enabled for trading.");
        require(state.getNumberOfRequests(_address) <= state.getNumberOfRequestsLimit() || state.getLastRequestBlock(_address) < block.number, "Request exceeded maximum number of requests permissioned per block.");
        state.setLastRequestBlock(_address);
        state.increaseNumberOfRequests(_address);
        orderNonce++;
        _orderId = keccak256(
            abi.encodePacked(
                _address,
                block.number,
                _marketId,
                _tradeAmountGivenInShares,
                _tradeAmount,
                _tradeDirection,
                _orderLeverage,
                orderNonce
                )
            );
        // FOR DEBUGGING
        lastOrderId = _orderId;
        orders[_orderId].userId = _address;
        orders[_orderId].marketId = _marketId;
        orders[_orderId].tradeAmountGivenInShares = _tradeAmountGivenInShares;
        orders[_orderId].tradeAmount = _tradeAmount;
        orders[_orderId].tradeDirection = _tradeDirection;
        orders[_orderId].orderLeverage = _orderLeverage;
        return _orderId;
    }

// ----------------------------------------------------------------------------
// Getter functions for orders, positions, and balance
// ----------------------------------------------------------------------------

    function getOrder(bytes32 _orderId) public view returns (
        address _userId,
        bytes32 _marketId,
        uint256 _tradeAmount,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _orderLeverage
        ) {
        require(msg.sender == orders[_orderId].userId || msg.sender == state.getAdministrator(), "You can only get your own orders.");
        return(
            orders[_orderId].userId,
            orders[_orderId].marketId,
            orders[_orderId].tradeAmount,
            orders[_orderId].marketPrice,
            orders[_orderId].marketSpread,
            orders[_orderId].orderLeverage
            );
    }

    function getOrderShares(bytes32 _orderId) public view returns (uint256 _longSharesOrder, uint256 _shortSharesOrder, uint256 _tradeAmount, bool _tradeDirection, uint256 _balanceUp, uint256 _balanceDown) {
        require(msg.sender == orders[_orderId].userId || msg.sender == state.getAdministrator(), "You can only get your own orders.");
        return(orders[_orderId].longSharesOrder, orders[_orderId].shortSharesOrder, orders[_orderId].tradeAmount, orders[_orderId].tradeDirection, orders[_orderId].balanceUp, orders[_orderId].balanceDown);
    }

    function getPosition(address _address, bytes32 _marketId) public view returns (
        uint256 _positionLongShares,
        uint256 _positionShortShares,
        uint256 _positionAveragePrice,
        uint256 _positionAverageSpread,
        uint256 _positionAverageLeverage,
        uint256 _liquidationPrice
        ) {
//        require(msg.sender == _address || msg.sender == state.getAdministrator(), "Only user or Administrator may view position.");
        return(
            state.getLongShares(_address, _marketId),
            state.getShortShares(_address, _marketId),
            state.getMeanEntryPrice(_address,_marketId),
            state.getMeanEntrySpread(_address,_marketId),
            state.getMeanEntryLeverage(_address,_marketId),
            state.getLiquidationPrice(_address,_marketId)
            );
    }


// ----------------------------------------------------------------------------
// liquidate(bytes32 _orderId)
// Checks for bankruptcy of position between its last update and now
// Time check is necessary to avoid two consecutive / unorderded liquidations
// ----------------------------------------------------------------------------

    function liquidate(bytes32 _orderId) private returns (bool _success) {
        address _address = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;
        uint256 _liquidationTimestamp = orders[_orderId].liquidationTimestamp;
        if (_liquidationTimestamp > state.getLastUpdated(_address, _marketId)) {
            if (state.getLongShares(_address,_marketId) > 0) {
                state.setPosition(_address, _marketId, orders[_orderId].timeStamp, 0, state.getShortShares(_address, _marketId), 0, 0, PRECISION, 0);
                emit LongPositionLiquidated(_address, _marketId, orders[_orderId].timeStamp, orders[_orderId].marketPrice, orders[_orderId].marketSpread, block.number, block.timestamp);
            }
            if (state.getShortShares(_address,_marketId) > 0) {
                state.setPosition(_address, _marketId, orders[_orderId].timeStamp, state.getLongShares(_address, _marketId), 0, 0, 0, PRECISION, 0);
                emit ShortPositionLiquidated(_address, _marketId, orders[_orderId].timeStamp, orders[_orderId].marketPrice, orders[_orderId].marketSpread, block.number, block.timestamp);
            }
            return true;
        } else {
            return false;
        }
    }

// ----------------------------------------------------------------------------
// processOrder(bytes32 _orderId, uint256 _marketPrice, uint256 _marketSpread, uint256 _liquidationTimestamp, uint256 _timeStamp)
// ProcessOrder receives the price/spread/liqidation information from the Oracle and
// triggers the processing of the order. If successful, processOrder updates the portfolio state.
// Liquidation time check is necessary to avoid two consecutive / unorderded liquidations
// ----------------------------------------------------------------------------

    function processOrder(
        bytes32 _orderId,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _liquidationTimestamp,
        uint256 _timeStamp
        ) public onlyOracle returns (
            uint256 _newLongShares,
            uint256 _newShortShares,
            uint256 _newAverageEntry,
            uint256 _newAverageSpread,
            uint256 _newAverageLeverage,
            uint256 _liquidationPrice
            ) {
        // Require order not deleted by user or admin
        require(orders[_orderId].userId > address(0), "Unable to process, order has been deleted.");
        require(_marketPrice > 0, "Market priced at zero. Buy order cannot be processed.");
        require(_marketPrice >= _marketSpread, "Market price lower then market spread. Order cannot be processed.");
        address _address = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;
        require(state.getMarketActive(_marketId) == true, "Market unknown or currently not enabled for trading.");
        orders[_orderId].marketPrice = _marketPrice;
        orders[_orderId].marketSpread = _marketSpread;
        orders[_orderId].timeStamp = _timeStamp;
        orders[_orderId].liquidationTimestamp = _liquidationTimestamp;

        // Check if previous position on that market was liquidated
        if (_liquidationTimestamp > state.getLastUpdated(_address, _marketId)) {
            liquidate(_orderId);
        }
        
		if (orders[_orderId].tradeAmount > 0)  {
            if (orders[_orderId].tradeDirection) {
                processBuyOrder(_orderId);
            } else {
                processSellOrder(_orderId);
		    }
		}	

        // Track global exposure
        if (state.getLongShares(_address, _marketId) > 0 || state.getShortShares(_address, _marketId) > 0) {
            // CONTRACT TOO LARGE
            // addExposureByMarket(_marketId, _address);
        } else {
            // CONTRACT TOO LARGE
            // deleteExposureByMarket(_marketId, _address);
        }
        delete orders[_orderId];
        return (
            state.getLongShares(_address, _marketId),
            state.getShortShares(_address, _marketId),
            state.getMeanEntryPrice(_address,_marketId),
            state.getMeanEntrySpread(_address,_marketId),
            state.getMeanEntryLeverage(_address,_marketId),
            state.getLiquidationPrice(_address,_marketId)
            );
    }

// ----------------------------------------------------------------------------
// function adminCancelOrder(bytes32 _orderId)
// Administrator can delete a pending order
// ----------------------------------------------------------------------------
    function adminCancelOrder(bytes32 _orderId) public onlyAdministrator returns (bool _success) {
        require(orders[_orderId].userId > address(0), "Unable to process, order does not exist.");
        delete orders[_orderId];
        emit CancelOrder(_orderId, state.getAdministrator(), block.number, block.timestamp);
        return true;
    }

// ----------------------------------------------------------------------------
// function userCancelOrder(bytes32 _orderId)
// Users can delete their own pending orders before the callback went through
// ----------------------------------------------------------------------------
    function userCancelOrder(bytes32 _orderId, address _address) public onlyOracle returns (bool _success) {
        require(_address == orders[_orderId].userId, "Cannot cancel an order of another address.");
        require(orders[_orderId].userId > address(0), "Unable to process, order does not exist.");
        delete orders[_orderId];
        emit CancelOrder(_orderId, _address, block.number, block.timestamp);
        return true;
    }

// ----------------------------------------------------------------------------
// shortShareValue / longShareValue compute the value of a virtual share
// given current price/spread/leverage of the market and mean price/spread/leverage
// at the beginning of the trade
// ----------------------------------------------------------------------------
    function shortShareValue(
        uint256 _positionAveragePrice,
        uint256 _positionAverageLeverage,
        uint256 _liquidationPrice,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _orderLeverage,
        bool _sell
        ) public pure returns (uint256 _shareValue) {
        if (_positionAverageLeverage < PRECISION) {
            // Leverage can never be less than 1. Fail safe for empty positions, i.e. undefined _positionAverageLeverage
            _positionAverageLeverage = PRECISION;
        }
        if (_sell == false) {
            // New short position
            // It costs marketPrice + marketSpread to build up a new short position
            _positionAveragePrice = _marketPrice;
	        // This is the average Leverage
	        _positionAverageLeverage = _orderLeverage;
        }
        if (
            _liquidationPrice <= _marketPrice
            ) {
	        // Position is worthless
            _shareValue = 0;
        } else {
            // The regular share value is 2x the entry price minus the current price for short positions.
            _shareValue = _positionAveragePrice.mul((PRECISION.add(_positionAverageLeverage))).div(PRECISION);
            _shareValue = _shareValue.sub(_marketPrice.mul(_positionAverageLeverage).div(PRECISION));
            if (_sell == true) {
                // We have to reduce the share value by the average spread (i.e. the average expense to build up the position)
                // and reduce the value further by the spread for selling.
                _shareValue = _shareValue.sub(_marketSpread.mul(_positionAverageLeverage).div(PRECISION));
            } else {
                // If a new short position is built up each share costs value + spread
                _shareValue = _shareValue.add(_marketSpread.mul(_orderLeverage).div(PRECISION));
            }
        }
        return _shareValue;
    }

    function longShareValue(
        uint256 _positionAveragePrice,
        uint256 _positionAverageLeverage,
        uint256 _liquidationPrice,
        uint256 _marketPrice,
        uint256 _marketSpread,
        uint256 _orderLeverage,
        bool _sell
        ) public pure returns (uint256 _shareValue) {
        if (_positionAverageLeverage < PRECISION) {
            // Leverage can never be less than 1. Fail safe for empty positions, i.e. undefined _positionAverageLeverage
            _positionAverageLeverage = PRECISION;
        }
        if (_sell == false) {
            // New long position
            // It costs marketPrice + marketSpread to build up a new long position
            _positionAveragePrice = _marketPrice;
	        // This is the average Leverage
	        _positionAverageLeverage = _orderLeverage;
        }
        if (
            _marketPrice <= _liquidationPrice
            ) {
	        // Position is worthless
            _shareValue = 0;
        } else {
            _shareValue = _positionAveragePrice.mul(_positionAverageLeverage.sub(PRECISION)).div(PRECISION);
            // The regular share value is market price times leverage minus entry price times entry leverage minus one.
            _shareValue = (_marketPrice.mul(_positionAverageLeverage).div(PRECISION)).sub(_shareValue);
            if (_sell == true) {
                // We sell a long and have to correct the shareValue with the averageSpread and the currentSpread for selling.
                _shareValue = _shareValue.sub(_marketSpread.mul(_positionAverageLeverage).div(PRECISION));
            } else {
                // We buy a new long position and have to pay the spread
                _shareValue = _shareValue.add(_marketSpread.mul(_orderLeverage).div(PRECISION));
            }
        }
        return _shareValue;
    }


// ----------------------------------------------------------------------------
// processBuyOrder(bytes32 _orderId)
// Converts orders specified in virtual shares to orders specified in Morpher token
// and computes the number of short shares that are sold and long shares that are bought.
// long shares are bought only if the order amount exceeds all open short positions
// ----------------------------------------------------------------------------

    function processBuyOrder(bytes32 _orderId) private returns (bool _success) {
        if (orders[_orderId].tradeAmountGivenInShares == false) {
            // Investment was specified in units of MPH
            if (orders[_orderId].tradeAmount <= state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId).mul(shortShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true))) {
                // Partial closing of short position
                orders[_orderId].longSharesOrder = 0;
                orders[_orderId].shortSharesOrder = orders[_orderId].tradeAmount.div(shortShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true));
            } else {
                // Closing of entire short position
                orders[_orderId].shortSharesOrder = state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId);
                orders[_orderId].longSharesOrder = orders[_orderId].tradeAmount.sub((state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId).mul(shortShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true))));
                orders[_orderId].longSharesOrder = orders[_orderId].longSharesOrder.div(longShareValue(orders[_orderId].marketPrice, orders[_orderId].orderLeverage, 0, orders[_orderId].marketPrice, orders[_orderId].marketSpread, orders[_orderId].orderLeverage, false)) ;
            }
        } else {
            // Investment was specified in shares
            if (orders[_orderId].tradeAmount <= state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId)) {
                // Partial closing of short position
                orders[_orderId].longSharesOrder = 0;
                orders[_orderId].shortSharesOrder = orders[_orderId].tradeAmount;
            } else {
                // Closing of entire short position
                orders[_orderId].shortSharesOrder = state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId);
                orders[_orderId].longSharesOrder = orders[_orderId].tradeAmount.sub(state.getShortShares(orders[_orderId].userId, orders[_orderId].marketId));
            }
        }
        buyIt(_orderId);
        return true;
    }

    function buyIt(bytes32 _orderId) private returns (bool _success) {
        // Investment equals number of shares now.
        if (orders[_orderId].shortSharesOrder > 0) {
            closeShort(_orderId);
        }
        if (orders[_orderId].longSharesOrder > 0) {
            openLong(_orderId);
        }
        return true;
    }

// ----------------------------------------------------------------------------
// processSellOrder(bytes32 _orderId)
// Converts orders specified in virtual shares to orders specified in Morpher token
// and computes the number of long shares that are sold and short shares that are bought.
// short shares are bought only if the order amount exceeds all open long positions
// ----------------------------------------------------------------------------

    function processSellOrder(bytes32 _orderId) private returns (bool _success) {
        if (orders[_orderId].tradeAmountGivenInShares == false) {
            // Investment was specified in units of MPH
            if (orders[_orderId].tradeAmount <= state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId).mul(longShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true))) {
                // Partial closing of long position
                orders[_orderId].shortSharesOrder = 0;
                orders[_orderId].longSharesOrder = orders[_orderId].tradeAmount.div(longShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true));
            } else {
                // Closing of entire long position
                orders[_orderId].longSharesOrder = state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId);
                orders[_orderId].shortSharesOrder = orders[_orderId].tradeAmount.sub((state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId).mul(longShareValue(state.getMeanEntryPrice(orders[_orderId].userId, orders[_orderId].marketId), state.getMeanEntryLeverage(orders[_orderId].userId, orders[_orderId].marketId), state.getLiquidationPrice(orders[_orderId].userId, orders[_orderId].marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, PRECISION, true))));
                orders[_orderId].shortSharesOrder = orders[_orderId].shortSharesOrder.div(shortShareValue(orders[_orderId].marketPrice, orders[_orderId].orderLeverage, orders[_orderId].marketPrice.mul(100), orders[_orderId].marketPrice, orders[_orderId].marketSpread, orders[_orderId].orderLeverage, false));
            }
        } else {
            // Investment was specified in shares
            if (orders[_orderId].tradeAmount <= state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId)) {
                // Partial closing of long position
                orders[_orderId].shortSharesOrder = 0;
                orders[_orderId].longSharesOrder = orders[_orderId].tradeAmount;
            } else {
                // Closing of entire long position
                orders[_orderId].longSharesOrder = state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId);
                orders[_orderId].shortSharesOrder = orders[_orderId].tradeAmount.sub(state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId));
            }
        }
        sellIt(_orderId);
        return true;
    }

    function sellIt(bytes32 _orderId) public returns (bool _success) {
        // Investment equals number of shares now.
        if (orders[_orderId].longSharesOrder > 0) {
            closeLong(_orderId);
        }
        if (orders[_orderId].shortSharesOrder > 0) {
            openShort(_orderId);
        }

        return true;
    }

// ----------------------------------------------------------------------------
// openLong(bytes32 _orderId)
// Opens a new long position and computes the new resulting average entry price/spread/leverage.
// Computation is broken down to several instructions for readability.
// ----------------------------------------------------------------------------
    function openLong(bytes32 _orderId) private {
        address _userId = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;

        //uint256 _newMeanEntry;
        uint256 _newMeanSpread;
        uint256 _newMeanLeverage;
        //
        // Existing position is virtually liquidated and reopened with current marketPrice
        // orders[_orderId].newMeanEntryPrice = orders[_orderId].marketPrice;
        
        // _factorLongShares is a factor to adjust the existing longShares via virtual liqudiation and reopening at current market price
        uint256 _factorLongShares = state.getMeanEntryLeverage(_userId, _marketId);
        if (_factorLongShares < PRECISION) {
            _factorLongShares = PRECISION;
        }
        _factorLongShares = _factorLongShares.sub(PRECISION);
        _factorLongShares = _factorLongShares.mul(state.getMeanEntryPrice(_userId, _marketId)).div(orders[_orderId].marketPrice);
        if (state.getMeanEntryLeverage(_userId, _marketId) > _factorLongShares) {
            _factorLongShares = state.getMeanEntryLeverage(_userId, _marketId).sub(_factorLongShares);
        } else {
            _factorLongShares = 0;
        }
        
        uint256 _adjustedLongShares = _factorLongShares.mul(state.getLongShares(_userId, _marketId)).div(PRECISION);
        
        // _newMeanLeverage is the weighted leverage of the existing position and the new position
        _newMeanLeverage = state.getMeanEntryLeverage(_userId, _marketId).mul(_adjustedLongShares);
        _newMeanLeverage = _newMeanLeverage.add(orders[_orderId].orderLeverage.mul(orders[_orderId].longSharesOrder));
        _newMeanLeverage = _newMeanLeverage.div(_adjustedLongShares.add(orders[_orderId].longSharesOrder));
        
        // _newMeanSpread is the weighted spread of the existing position and the new position
        _newMeanSpread = state.getMeanEntrySpread(_userId, _marketId).mul(state.getLongShares(_userId, _marketId));
        _newMeanSpread = _newMeanSpread.add(orders[_orderId].marketSpread.mul(orders[_orderId].longSharesOrder));
        _newMeanSpread = _newMeanSpread.div(_adjustedLongShares.add(orders[_orderId].longSharesOrder));
        
        orders[_orderId].balanceDown = orders[_orderId].longSharesOrder.mul(orders[_orderId].marketPrice).add(orders[_orderId].longSharesOrder.mul(orders[_orderId].marketSpread).mul(orders[_orderId].orderLeverage).div(PRECISION));
        orders[_orderId].balanceUp = 0;
        orders[_orderId].newLongShares = _adjustedLongShares.add(orders[_orderId].longSharesOrder);
        orders[_orderId].newShortShares = state.getShortShares(_userId, _marketId);
        orders[_orderId].newMeanEntryPrice = orders[_orderId].marketPrice;
        orders[_orderId].newMeanEntrySpread = _newMeanSpread;
        orders[_orderId].newMeanEntryLeverage = _newMeanLeverage;

        setPositionInState(_orderId);
    }

// ----------------------------------------------------------------------------
// closeLong(bytes32 _orderId)
// Closes an existing long position. Average entry price/spread/leverage do not change.
// ----------------------------------------------------------------------------
     function closeLong(bytes32 _orderId) private {
        address _userId = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;

        uint256 _newLongShares  = state.getLongShares(_userId, _marketId).sub(orders[_orderId].longSharesOrder);
        uint256 _balanceUp = orders[_orderId].longSharesOrder.mul(longShareValue(state.getMeanEntryPrice(_userId, _marketId), state.getMeanEntryLeverage(_userId, _marketId), state.getLiquidationPrice(_userId, _marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, state.getMeanEntryLeverage(_userId, _marketId), true));

        uint256 _newMeanEntry;
        uint256 _newMeanSpread;
        uint256 _newMeanLeverage;

        if (orders[_orderId].longSharesOrder == state.getLongShares(_userId, _marketId)) {
            _newMeanEntry = 0;
            _newMeanSpread = 0;
            _newMeanLeverage = PRECISION;
        } else {
            _newMeanEntry = state.getMeanEntryPrice(_userId, _marketId);
	        _newMeanSpread = state.getMeanEntrySpread(_userId, _marketId);
	        _newMeanLeverage = state.getMeanEntryLeverage(_userId, _marketId);
        }

        orders[_orderId].balanceDown = 0;
        orders[_orderId].balanceUp = _balanceUp;
        orders[_orderId].newLongShares = _newLongShares;
        orders[_orderId].newShortShares = state.getShortShares(_userId, _marketId);
        orders[_orderId].newMeanEntryPrice = _newMeanEntry;
        orders[_orderId].newMeanEntrySpread = _newMeanSpread;
        orders[_orderId].newMeanEntryLeverage = _newMeanLeverage;

        setPositionInState(_orderId);
    }

// ----------------------------------------------------------------------------
// closeShort(bytes32 _orderId)
// Closes an existing short position. Average entry price/spread/leverage do not change.
// ----------------------------------------------------------------------------

    function closeShort(bytes32 _orderId) private {
        address _userId = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;

        uint256 _newMeanEntry;
        uint256 _newMeanSpread;
        uint256 _newMeanLeverage;

        uint256 _newShortShares = state.getShortShares(_userId, _marketId).sub(orders[_orderId].shortSharesOrder);
        uint256 _balanceUp = orders[_orderId].shortSharesOrder.mul(shortShareValue(state.getMeanEntryPrice(_userId, _marketId), state.getMeanEntryLeverage(_userId, _marketId), state.getLiquidationPrice(_userId, _marketId), orders[_orderId].marketPrice, orders[_orderId].marketSpread, state.getMeanEntryLeverage(_userId, _marketId), true));

        if (orders[_orderId].shortSharesOrder == state.getShortShares(_userId, _marketId)) {
            _newMeanEntry = 0;
	        _newMeanSpread = 0;
	        _newMeanLeverage = PRECISION;
        } else {
            _newMeanEntry = state.getMeanEntryPrice(_userId, _marketId);
	        _newMeanSpread = state.getMeanEntrySpread(_userId, _marketId);
	        _newMeanLeverage = state.getMeanEntryLeverage(_userId, _marketId);
        }

        orders[_orderId].balanceDown = 0;
        orders[_orderId].balanceUp = _balanceUp;
        orders[_orderId].newLongShares = state.getLongShares(orders[_orderId].userId, orders[_orderId].marketId);
        orders[_orderId].newShortShares = _newShortShares;
        orders[_orderId].newMeanEntryPrice = _newMeanEntry;
        orders[_orderId].newMeanEntrySpread = _newMeanSpread;
        orders[_orderId].newMeanEntryLeverage = _newMeanLeverage;
        
        setPositionInState(_orderId);
    }

// ----------------------------------------------------------------------------
// openLong(bytes32 _orderId)
// Opens a new short position and computes the new resulting average entry price/spread/leverage.
// Computation is broken down to several instructions for readability.
// ----------------------------------------------------------------------------
    function openShort(bytes32 _orderId) private {
        address _userId = orders[_orderId].userId;
        bytes32 _marketId = orders[_orderId].marketId;

        //uint256 _newMeanEntry;
        uint256 _newMeanSpread;
        uint256 _newMeanLeverage;
        //
        // Existing position is virtually liquidated and reopened with current marketPrice
        // orders[_orderId].newMeanEntryPrice = orders[_orderId].marketPrice;
        
        // _factorLongShares is a factor to adjust the existing longShares via virtual liqudiation and reopening at current market price
        uint256 _factorShortShares = state.getMeanEntryLeverage(_userId, _marketId);
        if (_factorShortShares < PRECISION) {
            _factorShortShares = PRECISION;
        }
        _factorShortShares = _factorShortShares.add(PRECISION);
        _factorShortShares = _factorShortShares.mul(state.getMeanEntryPrice(_userId, _marketId)).div(orders[_orderId].marketPrice);
        if (state.getMeanEntryLeverage(_userId, _marketId) < _factorShortShares) {
            _factorShortShares = _factorShortShares.sub(state.getMeanEntryLeverage(_userId, _marketId));
        } else {
            _factorShortShares = 0;
        }
        
        uint256 _adjustedShortShares = _factorShortShares.mul(state.getShortShares(_userId, _marketId)).div(PRECISION);
        
        // _newMeanLeverage is the weighted leverage of the existing position and the new position
        _newMeanLeverage = state.getMeanEntryLeverage(_userId, _marketId).mul(_adjustedShortShares);
        _newMeanLeverage = _newMeanLeverage.add(orders[_orderId].orderLeverage.mul(orders[_orderId].shortSharesOrder));
        _newMeanLeverage = _newMeanLeverage.div(_adjustedShortShares.add(orders[_orderId].shortSharesOrder));
        
        // _newMeanSpread is the weighted spread of the existing position and the new position
        _newMeanSpread = state.getMeanEntrySpread(_userId, _marketId).mul(state.getShortShares(_userId, _marketId));
        _newMeanSpread = _newMeanSpread.add(orders[_orderId].marketSpread.mul(orders[_orderId].shortSharesOrder));
        _newMeanSpread = _newMeanSpread.div(_adjustedShortShares.add(orders[_orderId].shortSharesOrder));
        
        orders[_orderId].balanceDown = orders[_orderId].shortSharesOrder.mul(orders[_orderId].marketPrice).add(orders[_orderId].shortSharesOrder.mul(orders[_orderId].marketSpread).mul(orders[_orderId].orderLeverage).div(PRECISION));
        orders[_orderId].balanceUp = 0;
        orders[_orderId].newLongShares = state.getLongShares(_userId, _marketId);
        orders[_orderId].newShortShares = _adjustedShortShares.add(orders[_orderId].shortSharesOrder);
        orders[_orderId].newMeanEntryPrice = orders[_orderId].marketPrice;
        orders[_orderId].newMeanEntrySpread = _newMeanSpread;
        orders[_orderId].newMeanEntryLeverage = _newMeanLeverage;

        setPositionInState(_orderId);
    }

    function computeLiquidationPrice(bytes32 _orderId) public returns(uint256 _liquidationPrice) {
        orders[_orderId].newLiquidationPrice = 0;
        if (orders[_orderId].newLongShares > 0) {
            orders[_orderId].newLiquidationPrice = getLiquidationPrice(orders[_orderId].newMeanEntryPrice, orders[_orderId].newMeanEntryLeverage, true);
        }
        if (orders[_orderId].newShortShares > 0) {
            orders[_orderId].newLiquidationPrice = getLiquidationPrice(orders[_orderId].newMeanEntryPrice, orders[_orderId].newMeanEntryLeverage, false);
        }
        return orders[_orderId].newLiquidationPrice;
    }

    function getLiquidationPrice(uint256 _newMeanEntryPrice, uint256 _newMeanEntryLeverage, bool _long) public pure returns (uint256 _liquidiationPrice) {
        if (_long == true) {
            _liquidiationPrice = _newMeanEntryPrice.mul(_newMeanEntryLeverage.sub(PRECISION)).div(_newMeanEntryLeverage);
        } else {
            _liquidiationPrice = _newMeanEntryPrice.mul(_newMeanEntryLeverage.add(PRECISION)).div(_newMeanEntryLeverage);
        }
        return _liquidiationPrice;
    }

// ----------------------------------------------------------------------------
// setPositionInState(bytes32 _orderId)
// Updates the portfolio in Morpher State. Called by closeLong/closeShort/openLong/openShort
// ----------------------------------------------------------------------------
    function setPositionInState(bytes32 _orderId) private returns(bool _success) {
        require(state.balanceOf(orders[_orderId].userId).add(orders[_orderId].balanceUp) >= orders[_orderId].balanceDown, "Insufficient funds.");
        computeLiquidationPrice(_orderId);
        // Adding first, deleting after - potentially exploitable, consider refactoring
        state.addBalance(orders[_orderId].userId, orders[_orderId].balanceUp);
        state.subBalance(orders[_orderId].userId, orders[_orderId].balanceDown);
        state.setPosition(orders[_orderId].userId, orders[_orderId].marketId, orders[_orderId].timeStamp, orders[_orderId].newLongShares, orders[_orderId].newShortShares, orders[_orderId].newMeanEntryPrice, orders[_orderId].newMeanEntrySpread, orders[_orderId].newMeanEntryLeverage, orders[_orderId].newLiquidationPrice);
        return true;
    }
}