// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";

import "./VRFConsumerBaseV2Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { NftArenazPowersInterface } from "./NftArenazPowersInterface.sol";

contract NftDuel is Initializable, VRFConsumerBaseV2Upgradeable, ERC721HolderUpgradeable, UUPSUpgradeable, OwnableUpgradeable {
    enum CoinSide {
        HEAD,
        TAIL
    }
    enum GameStatus {
        None,
        WaitingForPlayers,
        InProgress,
        Completed,
        CompletedAndClaimed,
        Abandoned
    }
    struct Game {
        uint256 id;
        address nftContractAddress;
        Player player1;
        Player player2;
        Player winner;
        GameStatus status;
        uint256 timestamp;
    }
    struct GameReference {
        address nftContractAddress;
        uint256 gameId;
    }
    struct Player {
        address playerAddress;
        uint256 nftId;
        uint256 nftPower;
    }

    event PlayerCreatedGame(address indexed nftContractAddress, uint256 gameId, address playerAddress, uint256 playerNft);
    event PlayerJoinedGame(address indexed nftContractAddress, uint256 gameId, address playerAddress, uint256 playerNft);
    event PlayerLeftGame(address indexed nftContractAddress, uint256 gameId);
    event PlayerClaimedPrize(address indexed nftContractAddress, uint256 gameId);
    event GameCompleted(address indexed nftContractAddress, uint256 gameId, uint256 winnerNft);

    mapping(address => uint256) public gameCountPerProject;
    mapping(address => mapping(uint256 => Game)) public projectGames;
    mapping(address => uint256) public joinFees;
    mapping(address => uint256) public claimFees;
    mapping(uint256 => GameReference) private randomnessRequestsToGameIds;

    uint256 public defaultClaimFee;
    bytes32 public clMaxGasKeyHash;
    NftArenazPowersInterface public nftArenazPowers;
    uint64 public clSubscriptionId;
    uint32 public clCallbackGasLimit;
    uint16 public clRequestConfirmations;
    bool public isContractEnabled;
    VRFCoordinatorV2Interface public clCoordinator;

    function initialize(
        uint64 subscriptionId,
        address coordinatorAddress,
        bytes32 maxGasKeyHash,
        uint16 requestConfirmations,
        address nftArenazPowersAddress
    ) public initializer
    {
        isContractEnabled = true;
        clCallbackGasLimit = 2_500_000;
        clCoordinator = VRFCoordinatorV2Interface(coordinatorAddress);
        clSubscriptionId = subscriptionId;
        clMaxGasKeyHash = maxGasKeyHash;
        clRequestConfirmations = requestConfirmations;
        nftArenazPowers = NftArenazPowersInterface(nftArenazPowersAddress);
        defaultClaimFee = 0.05 ether;

       __Ownable_init();
       __VRFConsumerBaseV2_init(coordinatorAddress);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * PUBLIC API
     **/
    function getGamesBatch(address projectAddress, uint256 startIndex, uint256 batchSize) public view returns (Game[] memory) {
        require(startIndex < gameCountPerProject[projectAddress], "Start index is out of bounds");
        require(batchSize > 0, "Batch size must be greater than zero");

        uint256 arraySize = gameCountPerProject[projectAddress] - startIndex < batchSize
            ? gameCountPerProject[projectAddress] - startIndex
            : batchSize;
        Game[] memory gameList = new Game[](arraySize);

        uint256 endIndex = startIndex + batchSize;
        for (uint i = startIndex; i < endIndex && i < gameCountPerProject[projectAddress]; i++) {
            gameList[i - startIndex] = projectGames[projectAddress][i];
        }

        return gameList;
    }

    function createGame(address nftContractAddress, uint256 nftId, uint256 nftPower, bytes32[] calldata nftPowerMerkleProof) public payable {
        require(isContractEnabled, "Game is currently disabled");
        require(msg.value >= joinFees[nftContractAddress], "Provided fee is too low");
        require(nftArenazPowers.verifyNftPower(nftPowerMerkleProof, nftId, nftPower, nftContractAddress), "Invalid nft power proof");

        IERC721 nftContract = IERC721(nftContractAddress);
        requireNftApprovalAndOwnership(nftContract, nftId);

        nftContract.transferFrom(msg.sender, address(this), nftId);

        Game memory game;
        game.id = gameCountPerProject[nftContractAddress];
        game.nftContractAddress = nftContractAddress;
        game.player1 = Player(msg.sender, nftId, nftPower);
        game.status =  GameStatus.WaitingForPlayers;
        game.timestamp = block.timestamp;
        projectGames[nftContractAddress][game.id] = game;

        unchecked { ++gameCountPerProject[nftContractAddress]; }
        emit PlayerCreatedGame(nftContractAddress, game.id, msg.sender, nftId);
    }

    function joinGame(address nftContractAddress, uint256 gameId, uint256 nftId, uint256 nftPower, bytes32[] calldata nftPowerMerkleProof) public payable {
        require(isContractEnabled, "Game is currently disabled");
        require(projectGames[nftContractAddress][gameId].status == GameStatus.WaitingForPlayers, "Game with given id doesn't exist or is already in progress");
        require(msg.value >= joinFees[nftContractAddress], "Provided fee is too low");
        require(nftArenazPowers.verifyNftPower(nftPowerMerkleProof, nftId, nftPower, nftContractAddress), "Invalid nft power proof");

        IERC721 nftContract = IERC721(nftContractAddress);
        requireNftApprovalAndOwnership(nftContract, nftId);

        projectGames[nftContractAddress][gameId].status = GameStatus.InProgress;
        projectGames[nftContractAddress][gameId].player2 = Player(msg.sender, nftId, nftPower);
        projectGames[nftContractAddress][gameId].timestamp = block.timestamp;

        nftContract.transferFrom(msg.sender, address(this), nftId);

        requestRandomWords(nftContractAddress, gameId);

        emit PlayerJoinedGame(nftContractAddress, gameId, msg.sender, nftId);
    }

    function leaveGame(address nftContractAddress, uint256 gameId) public {
        require(projectGames[nftContractAddress][gameId].status == GameStatus.WaitingForPlayers, "Game with given id doesn't exist or is already in progress");
        require(projectGames[nftContractAddress][gameId].player1.playerAddress == msg.sender, "You are not participating in this game");

        projectGames[nftContractAddress][gameId].status = GameStatus.Abandoned;
        projectGames[nftContractAddress][gameId].timestamp = block.timestamp;

        IERC721 nftContract = IERC721(nftContractAddress);
        nftContract.transferFrom(address(this), msg.sender, projectGames[nftContractAddress][gameId].player1.nftId);

        emit PlayerLeftGame(nftContractAddress, gameId);
    }

    function claimPrize(address nftContractAddress, uint256 gameId) public payable {
        require(projectGames[nftContractAddress][gameId].status == GameStatus.Completed, "Game with given id isn't completed yet or NFTs have already been claimed");
        require(projectGames[nftContractAddress][gameId].winner.playerAddress == msg.sender, "You are not a winner of this game");
        uint256 expectedFee = claimFees[nftContractAddress] == 0 ? defaultClaimFee : claimFees[nftContractAddress];
        require(msg.value >= expectedFee, "Provided fee is too low");

        projectGames[nftContractAddress][gameId].status = GameStatus.CompletedAndClaimed;

        IERC721 nftContract = IERC721(nftContractAddress);
        nftContract.transferFrom(address(this), msg.sender, projectGames[nftContractAddress][gameId].player1.nftId);
        nftContract.transferFrom(address(this), msg.sender, projectGames[nftContractAddress][gameId].player2.nftId);

        emit PlayerClaimedPrize(projectGames[nftContractAddress][gameId].nftContractAddress, gameId);
    }

    function requestRandomWords(address nftContractAddress, uint256 gameId) private
    {
        uint256 requestId = clCoordinator.requestRandomWords(
            clMaxGasKeyHash,
            clSubscriptionId,
            clRequestConfirmations,
            clCallbackGasLimit,
            1
        );
        randomnessRequestsToGameIds[requestId] = GameReference(nftContractAddress, gameId);
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        uint256 gameId = randomnessRequestsToGameIds[_requestId].gameId;
        address nftContractAddress = randomnessRequestsToGameIds[_requestId].nftContractAddress;
        require(projectGames[nftContractAddress][gameId].status == GameStatus.InProgress, "Game with given id is not in progress.");

        projectGames[nftContractAddress][gameId].status = GameStatus.Completed;
        projectGames[nftContractAddress][gameId].timestamp = block.timestamp;

        uint256 totalNftPower = projectGames[nftContractAddress][gameId].player1.nftPower + projectGames[nftContractAddress][gameId].player2.nftPower;
        projectGames[nftContractAddress][gameId].winner = _randomWords[0] % totalNftPower < projectGames[nftContractAddress][gameId].player1.nftPower
            ? projectGames[nftContractAddress][gameId].player1
            : projectGames[nftContractAddress][gameId].player2;

        emit GameCompleted(nftContractAddress, gameId, projectGames[nftContractAddress][gameId].winner.nftId);
    }

    function requireNftApprovalAndOwnership(IERC721 nftContract, uint256 nftId) private view {
        require(nftContract.ownerOf(nftId) == msg.sender, "You are not the owner of the NFT");
        require(nftContract.isApprovedForAll(msg.sender, address(this)), "Approval for NFT was not set");
    }

    /**
     * OWNER ONLY API
     **/
    function retryRandomWordsRequest(address nftContractAddress, uint256 gameId) external onlyOwner {
        require(projectGames[nftContractAddress][gameId].status == GameStatus.InProgress, "Game with given id is not in progress.");
        requestRandomWords(nftContractAddress, gameId);
    }

    function setVrfCoordinator(address vrfCoordinator) external onlyOwner
    {
        clCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
    }

    function setSubscriptionId(uint64 subscriptionId) external onlyOwner
    {
        clSubscriptionId = subscriptionId;
    }

    function setCallbackGasLimit(uint32 callbackGasLimit) external onlyOwner
    {
        clCallbackGasLimit = callbackGasLimit;
    }

    function setMaxGasKeyHash(bytes32 maxGasKeyHash) external onlyOwner
    {
        clMaxGasKeyHash = maxGasKeyHash;
    }

    function setRequestConfirmations(uint16 requestConfirmations) external onlyOwner
    {
        clRequestConfirmations = requestConfirmations;
    }

    function setFees(address nftProjectAddress, uint256 joinFee, uint256 claimFee) external onlyOwner
    {
        joinFees[nftProjectAddress] = joinFee;
        claimFees[nftProjectAddress] = claimFee;
    }

    function setJoinFee(address nftProjectAddress, uint256 joinFee) external onlyOwner
    {
        joinFees[nftProjectAddress] = joinFee;
    }

    function setClaimFee(address nftProjectAddress, uint256 claimFee) external onlyOwner
    {
        claimFees[nftProjectAddress] = claimFee;
    }

    function setDefaultClaimFee(uint256 claimFee) external onlyOwner
    {
        defaultClaimFee = claimFee;
    }
    
    function triggerContract() external onlyOwner
    {
        isContractEnabled = !isContractEnabled;
    }

    function withdraw() external onlyOwner  {
        address _owner = owner();
        uint256 amount = address(this).balance;
        (bool sent, ) =  _owner.call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
}
