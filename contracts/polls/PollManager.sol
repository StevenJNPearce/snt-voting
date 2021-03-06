pragma solidity ^0.4.24;

import "../common/Controlled.sol";
import "../token/MiniMeToken.sol";
import "../rlp/RLPHelper.sol";


contract PollManager is Controlled {

    struct Poll {
        uint startBlock;
        uint endBlock;
        bool canceled;
        uint voters;
        bytes description;
        uint8 numBallots;
        mapping(uint8 => mapping(address => uint)) ballots;
        mapping(uint8 => uint) qvResults;
        mapping(uint8 => uint) results;
        address author;
    }

    Poll[] _polls;

    MiniMeToken public token;

    RLPHelper public rlpHelper;

    /// @notice Contract constructor
    /// @param _token Address of the token used for governance
    constructor(address _token) 
        public {
        token = MiniMeToken(_token);
        rlpHelper = new RLPHelper();
    }

    /// @notice Only allow addresses that have > 0 SNT to perform an operation
    modifier onlySNTHolder {
        require(token.balanceOf(msg.sender) > 0, "SNT Balance is required to perform this operation"); 
        _; 
    }

    /// @notice Create a Poll and enable it immediatly
    /// @param _endBlock Block where the poll ends
    /// @param _description RLP encoded: [poll_title, [poll_ballots]]
    /// @param _numBallots Number of ballots
    function addPoll(
        uint _endBlock,
        bytes _description,
        uint8 _numBallots)
        public
        onlySNTHolder
        returns (uint _idPoll)
    {
        _idPoll = addPoll(block.number, _endBlock, _description, _numBallots);
    }

    /// @notice Create a Poll
    /// @param _startBlock Block where the poll starts
    /// @param _endBlock Block where the poll ends
    /// @param _description RLP encoded: [poll_title, [poll_ballots]]
    /// @param _numBallots Number of ballots
    function addPoll(
        uint _startBlock,
        uint _endBlock,
        bytes _description,
        uint8 _numBallots)
        public
        onlySNTHolder
        returns (uint _idPoll)
    {
        require(_endBlock > block.number, "End block must be greater than current block");
        require(_startBlock >= block.number && _startBlock < _endBlock, "Start block must not be in the past, and should be less than the end block" );
        require(_numBallots <= 15, "Only a max of 15 ballots are allowed");

        _idPoll = _polls.length;
        _polls.length ++;

        Poll storage p = _polls[_idPoll];
        p.startBlock = _startBlock;
        p.endBlock = _endBlock;
        p.voters = 0;
        p.numBallots = _numBallots;
        p.description = _description;
        p.author = msg.sender;

        emit PollCreated(_idPoll); 
    }

    /// @notice Update poll description (title or ballots) as long as it hasn't started
    /// @param _idPoll Poll to update
    /// @param _description RLP encoded: [poll_title, [poll_ballots]]
    /// @param _numBallots Number of ballots
    function updatePollDescription(
        uint _idPoll, 
        bytes _description,
        uint8 _numBallots)
        public
    {
        require(_idPoll < _polls.length, "Invalid _idPoll");
        require(_numBallots <= 15, "Only a max of 15 ballots are allowed");

        Poll storage p = _polls[_idPoll];
        require(p.startBlock > block.number, "You cannot modify an active poll");
        require(p.author == msg.sender || msg.sender == controller, "Only the owner/controller can modify the poll");

        p.numBallots = _numBallots;
        p.description = _description;
        p.author = msg.sender;
    }

    /// @notice Cancel an existing poll
    /// @dev Can only be done by the controller (which should be a Multisig/DAO) at any time, or by the owner if the poll hasn't started
    /// @param _idPoll Poll to cancel
    function cancelPoll(uint _idPoll) 
        public {
        require(_idPoll < _polls.length, "Invalid _idPoll");

        Poll storage p = _polls[_idPoll];
        
        require(!p.canceled, "Poll has been canceled already");
        require(p.endBlock > block.number, "Only active polls can be canceled");

        if(p.startBlock < block.number){
            require(msg.sender == controller, "Only the controller can cancel the poll");
        } else {
            require(p.author == msg.sender, "Only the owner can cancel the poll");
        }

        p.canceled = true;

        emit PollCanceled(_idPoll);
    }

    /// @notice Determine if user can bote for a poll
    /// @param _idPoll Id of the poll
    /// @return bool Can vote or not
    function canVote(uint _idPoll) 
        public 
        view 
        returns(bool)
    {
        if(_idPoll >= _polls.length) return false;

        Poll storage p = _polls[_idPoll];
        uint balance = token.balanceOfAt(msg.sender, p.startBlock);
        return block.number >= p.startBlock && block.number < p.endBlock && !p.canceled && balance != 0;
    }
    
    /// @notice Calculate square root of a uint (It has some precision loss)
    /// @param x Number to calculate the square root
    /// @return Square root of x
    function sqrt(uint256 x) public pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Vote for a poll
    /// @param _idPoll Poll to vote
    /// @param _ballots array of (number of ballots the poll has) elements, and their sum must be less or equal to the balance at the block start
    function vote(uint _idPoll, uint[] _ballots) public {
        require(_idPoll < _polls.length, "Invalid _idPoll");

        Poll storage p = _polls[_idPoll];

        require(block.number >= p.startBlock && block.number < p.endBlock && !p.canceled, "Poll is inactive");
        require(_ballots.length == p.numBallots, "Number of ballots is incorrect");

        unvote(_idPoll);

        uint amount = token.balanceOfAt(msg.sender, p.startBlock);
        require(amount != 0, "No SNT balance available at start block of poll");

        p.voters++;

        uint totalBallots = 0;
        for(uint8 i = 0; i < _ballots.length; i++){
            totalBallots += _ballots[i];

            p.ballots[i][msg.sender] = _ballots[i];

            if(_ballots[i] != 0){
                p.qvResults[i] += sqrt(_ballots[i] / 1 ether);
                p.results[i] += _ballots[i];
            }
        }

        require(totalBallots <= amount, "Total ballots must be less than the SNT balance at poll start block");

        emit Vote(_idPoll, msg.sender, _ballots);
    }

    /// @notice Cancel or reset a vote
    /// @param _idPoll Poll 
    function unvote(uint _idPoll) public {
        require(_idPoll < _polls.length, "Invalid _idPoll");

        Poll storage p = _polls[_idPoll];
        
        require(block.number >= p.startBlock && block.number < p.endBlock && !p.canceled, "Poll is inactive");

        if(p.voters == 0) return;

        uint prevVotes = 0;
        for(uint8 i = 0; i < p.numBallots; i++){
            uint ballotAmount = p.ballots[i][msg.sender];

            prevVotes += ballotAmount;
            p.ballots[i][msg.sender] = 0;

            if(ballotAmount != 0){
                p.qvResults[i] -= sqrt(ballotAmount / 1 ether);
                p.results[i] -= ballotAmount;
            }
        }

        if(prevVotes != 0){
            p.voters--;
        }

        emit Unvote(_idPoll, msg.sender);
    }

    // Constant Helper Function

    /// @notice Get number of polls
    /// @return Num of polls
    function nPolls()
        public
        view 
        returns(uint)
    {
        return _polls.length;
    }

    /// @notice Get Poll info
    /// @param _idPoll Poll 
    function poll(uint _idPoll)
        public 
        view 
        returns(
        uint _startBlock,
        uint _endBlock,
        bool _canVote,
        bool _canceled,
        bytes _description,
        uint8 _numBallots,
        bool _finalized,
        uint _voters,
        address _author,
        uint[15] _tokenTotal,
        uint[15] _quadraticVotes
    )
    {
        require(_idPoll < _polls.length, "Invalid _idPoll");

        Poll storage p = _polls[_idPoll];

        _startBlock = p.startBlock;
        _endBlock = p.endBlock;
        _canceled = p.canceled;
        _canVote = canVote(_idPoll);
        _description = p.description;
        _numBallots = p.numBallots;
        _author = p.author;
        _finalized = (!p.canceled) && (block.number >= _endBlock);
        _voters = p.voters;

        for(uint8 i = 0; i < p.numBallots; i++){
            _tokenTotal[i] = p.results[i];
            _quadraticVotes[i] = p.qvResults[i];
        }
    }

    /// @notice Decode poll title
    /// @param _idPoll Poll
    /// @return string with the poll title
    function pollTitle(uint _idPoll) public view returns (string){
        require(_idPoll < _polls.length, "Invalid _idPoll");
        Poll memory p = _polls[_idPoll];

        return rlpHelper.pollTitle(p.description);
    }

    /// @notice Decode poll ballot
    /// @param _idPoll Poll
    /// @param _ballot Index (0-based) of the ballot to decode
    /// @return string with the ballot text
    function pollBallot(uint _idPoll, uint _ballot) public view returns (string){
        require(_idPoll < _polls.length, "Invalid _idPoll");
        Poll memory p = _polls[_idPoll];

        return rlpHelper.pollBallot(p.description, _ballot);
    }

    /// @notice Get votes for poll/ballot
    /// @param _idPoll Poll
    /// @param _voter Address of the voter
    function getVote(uint _idPoll, address _voter) 
        public 
        view 
        returns (uint[15] votes){
        require(_idPoll < _polls.length, "Invalid _idPoll");
        Poll storage p = _polls[_idPoll];
        for(uint8 i = 0; i < p.numBallots; i++){
            votes[i] = p.ballots[i][_voter];
        }
        return votes;
    }

    event Vote(uint indexed idPoll, address indexed _voter, uint[] ballots);
    event Unvote(uint indexed idPoll, address indexed _voter);
    event PollCanceled(uint indexed idPoll);
    event PollCreated(uint indexed idPoll);
}
