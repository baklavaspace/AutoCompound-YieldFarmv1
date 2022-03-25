// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BRTERC20.sol";
import "./IRouter.sol";
import "./IBavaMasterFarm.sol";
import "./IBavaToken.sol";
import "./IStakingRewards.sol";
import "./IWAVAX.sol";

// BavaCompoundPool is the compoundPool of BavaMasterFarmer. It will autocompound user LP.
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Bava is sufficiently
// distributed and the community can show to govern itself.

contract BavaCompoundPool_Png is BRTERC20 {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 receiptAmount;      // user receipt tokens.
        uint256 rewardDebt;         // Reward debt. See explanation below.
        uint256 rewardDebtAtBlock;  // the last block user stake
		uint256 lastWithdrawBlock;  // the last block a user withdrew at.
		uint256 firstDepositBlock;  // the first block a user deposited at.
		uint256 blockdelta;         // time passed since withdrawals
		uint256 lastDepositBlock;   // the last block a user deposited at.
    }

    // Info of pool.
    struct PoolInfo {
        IERC20 lpToken;             // Address of LP token contract.
        uint256 depositAmount;      // Total deposit amount
        bool deposits_enabled;
    }
    
    // Info of 3rd party restaking farm 
    struct PoolRestakingInfo {
        IStakingRewards pngStakingContract;       // PNG Staking contract
        // uint256 restakingFarmID;            // RestakingFarm ID
    }

    IWAVAX private constant WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);     // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
    IERC20 private constant USDCE = IERC20(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);     // 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664
    uint256 public MIN_TOKENS_TO_REINVEST;
    uint256 public DEV_FEE_BIPS;
    uint256 public REINVEST_REWARD_BIPS;
    uint256 constant internal BIPS_DIVISOR = 10000;

    IRouter public router;                  // Router
    IBAVAMasterFarm public BavaMasterFarm;  // MasterFarm to mint BAVA token.
    IBavaToken public Bava;                 // The Bava TOKEN!
    uint256 public bavaPid;                 // BAVA Master Farm Pool Id
    address public devaddr;                 // Developer/Employee address.
    address public liqaddr;                 // Liquidate address

    IERC20 public rewardToken;
    IERC20[] public bonusRewardTokens;
    uint256[] public blockDeltaStartStage;
    uint256[] public blockDeltaEndStage;
    uint256[] public userFeeStage;
    uint256 public userDepFee;
    uint256 public PERCENT_LOCK_BONUS_REWARD;           // lock xx% of bounus reward in 3 year

    PoolInfo public poolInfo;                           // Info of each pool.
    PoolRestakingInfo public poolRestakingInfo;         // Info of each pool restaking farm.
    mapping (address => UserInfo) public userInfo;      // Info of each user that stakes LP tokens. pid => user address => info

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 devAmount);
    event SendBavaReward(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockAmount);
    event DepositsEnabled(bool newValue);
    event Liquidate(address indexed userAccount, uint256 amount);

    mapping(address => bool) public authorized;

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    constructor(
        IBavaToken _IBava,
        IBAVAMasterFarm _BavaMasterFarm,
        address _devaddr,
        address _liqaddr,
        uint256 _userDepFee,
        uint256 _newlock,
        uint256 _bavaPid,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage
    ) {
        Bava = _IBava;
        BavaMasterFarm = _BavaMasterFarm;
        devaddr = _devaddr;
        liqaddr = _liqaddr;
	    userDepFee = _userDepFee;
        PERCENT_LOCK_BONUS_REWARD = _newlock; 
        bavaPid = _bavaPid;
	    blockDeltaStartStage = _blockDeltaStartStage;
	    blockDeltaEndStage = _blockDeltaEndStage;
	    userFeeStage = _userFeeStage;
    }

    /******************************************* INITIAL SETUP START ******************************************/
    // Init the pool. Can only be called by the owner. Support LP from pangolin miniChef.
    function initPool(IERC20 _lpToken, IStakingRewards _stakingPglContract, IERC20 _rewardToken, IERC20[] memory _bonusRewardTokens, IRouter _router, uint256 _MIN_TOKENS_TO_REINVEST, uint256 _DEV_FEE_BIPS, uint256 _REINVEST_REWARD_BIPS) external onlyOwner {        
        require(address(_lpToken) != address(0), "0Addr");
        require(address(_stakingPglContract) != address(0), "0Addr");

        poolInfo.lpToken = _lpToken;
        poolInfo.depositAmount = 0;
        poolInfo.deposits_enabled = true;
        
        poolRestakingInfo.pngStakingContract = _stakingPglContract;
        // poolRestakingInfo.restakingFarmID = _restakingFarmID;
        rewardToken = _rewardToken;
        bonusRewardTokens = _bonusRewardTokens;
        router = _router;
        MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
        DEV_FEE_BIPS = _DEV_FEE_BIPS;
        REINVEST_REWARD_BIPS = _REINVEST_REWARD_BIPS;
    }

    /**
     * @notice Approve tokens for use in Strategy, Restricted to avoid griefing attacks
     */
    function setAllowancesStaking(uint256 _amount) external onlyOwner {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;        
        if (address(poolRestaking.pngStakingContract) != address(0)) {
            poolInfo.lpToken.approve(address(poolRestaking.pngStakingContract), _amount);
        }
    }

    function setAllowancesRouter(uint256 _amount) external onlyOwner {
        if (address(router) != address(0)) {
            WAVAX.approve(address(router), _amount);
            poolInfo.lpToken.approve(address(router), _amount);
            if (address(poolInfo.lpToken) !=address(rewardToken)) {
                rewardToken.approve(address(router), _amount);
            }
            uint256 rewardLength = bonusRewardTokens.length;
            for (uint256 i; i < rewardLength; i++) {
                bonusRewardTokens[i].approve(address(router), _amount);
            }
        }
    }
    /******************************************** INITIAL SETUP END ********************************************/

    /****************************************** FARMING CORE FUNCTION ******************************************/
    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public {
        ( , , , uint256 lastRewardBlock, ) = BavaMasterFarm.poolInfo(bavaPid);
        if (block.number <= lastRewardBlock) {
            return;
        }
        BavaMasterFarm.updatePool(bavaPid);
    }

    function claimReward() public {
        updatePool();
        _harvest(msg.sender);
    }

    // lock 95% of reward
    function _harvest(address account) private {
        UserInfo storage user = userInfo[account];
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);
        if (user.receiptAmount > 0) {
            uint256 pending = user.receiptAmount*(accBavaPerShare)/(1e12)-(user.rewardDebt);
            uint256 masterBal = Bava.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }
            
            if(pending > 0) {
                Bava.transfer(account, pending);
                uint256 lockAmount = 0;
                lockAmount = pending*(PERCENT_LOCK_BONUS_REWARD)/(100);
                Bava.lock(account, lockAmount);

                user.rewardDebtAtBlock = block.number;

                emit SendBavaReward(account, bavaPid, pending, lockAmount);
            }
            user.rewardDebt = user.receiptAmount*(accBavaPerShare)/(1e12);
        }
    }
    
    // Deposit LP tokens to BavaMasterFarmer for $Bava allocation.
    function deposit(uint256 _amount) public {
        require(_amount > 0, "#<0");
        require(poolInfo.deposits_enabled == true, "False");

        UserInfo storage user = userInfo[msg.sender];
        UserInfo storage devr = userInfo[devaddr];

        (uint256 estimatedTotalReward, ) = checkReward();
        if (estimatedTotalReward > MIN_TOKENS_TO_REINVEST) {
            _reinvest();
        }

        updatePool();
        _harvest(msg.sender);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);
        
        poolInfo.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        uint poolReceiptAmount = getSharesForDepositTokens(_amount);
        poolInfo.depositAmount += _amount;

        if (user.receiptAmount == 0) {
            user.rewardDebtAtBlock = block.number;
        }
        uint userReceiptAmount = poolReceiptAmount - (poolReceiptAmount * userDepFee / 10000);  
        uint devrReceiptAmount = poolReceiptAmount - userReceiptAmount;

        user.receiptAmount += userReceiptAmount;
        user.rewardDebt = user.receiptAmount * (accBavaPerShare) / (1e12);
        devr.receiptAmount += devrReceiptAmount;
        devr.rewardDebt = devr.receiptAmount * (accBavaPerShare) / (1e12);
        _mint(msg.sender, userReceiptAmount);
        _mint(devaddr, devrReceiptAmount);

        _stakeDepositTokens(_amount);
        
        emit Deposit(msg.sender, bavaPid, _amount);
		if(user.firstDepositBlock > 0){
		} else {
			user.firstDepositBlock = block.number;
		}
		user.lastDepositBlock = block.number;
    }
    
  // Withdraw LP tokens from BavaMasterFarmer. argument "_amount" is receipt amount.
    function withdraw(uint256 _amount) public {
        UserInfo storage user = userInfo[msg.sender];
        uint depositTokenAmount = getDepositTokensForShares(_amount);
        require(poolInfo.depositAmount >= depositTokenAmount, "#>Bal");
        require(user.receiptAmount >= _amount, "#>Stake");
        updatePool();
        _harvest(msg.sender);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        if(depositTokenAmount > 0) {
            _withdrawDepositTokens(depositTokenAmount);
            user.receiptAmount = user.receiptAmount-(_amount);
            _burn(msg.sender, _amount);
			if(user.lastWithdrawBlock > 0){
				user.blockdelta = block.number - user.lastWithdrawBlock; 
            } else {
                user.blockdelta = block.number - user.firstDepositBlock;
			}
            poolInfo.depositAmount -= depositTokenAmount;
            user.rewardDebt = user.receiptAmount*(accBavaPerShare)/(1e12);
            user.lastWithdrawBlock = block.number;
			if(user.blockdelta == blockDeltaStartStage[0] || block.number == user.lastDepositBlock){
				//25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[0])/100;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[1] && user.blockdelta <= blockDeltaEndStage[0]){
				//8% fee if a user deposits and withdraws in under between same block and 59 minutes.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[1])/100;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[2] && user.blockdelta <= blockDeltaEndStage[1]){
				//4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[2])/100;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[3] && user.blockdelta <= blockDeltaEndStage[2]){
				//2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[3])/100;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[4] && user.blockdelta <= blockDeltaEndStage[3]){
				//1% fee if a user deposits and withdraws after 3 days but before 5 days.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[4])/100;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			}  else if (user.blockdelta >= blockDeltaStartStage[5] && user.blockdelta <= blockDeltaEndStage[4]){
				//0.5% fee if a user deposits and withdraws if the user withdraws after 5 days but before 2 weeks.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[5])/1000;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[6] && user.blockdelta <= blockDeltaEndStage[5]){
				//0.25% fee if a user deposits and withdraws after 2 weeks.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[6])/10000;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			} else if (user.blockdelta > blockDeltaStartStage[7]) {
				//0.1% fee if a user deposits and withdraws after 4 weeks.
                uint256 userWithdrawFee = depositTokenAmount*(userFeeStage[7])/10000;
				poolInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				poolInfo.lpToken.safeTransfer(address(devaddr), depositTokenAmount-userWithdrawFee);
			}
            emit Withdraw(msg.sender, bavaPid, depositTokenAmount);
		}
    }

    // EMERGENCY ONLY. Withdraw without caring about rewards.  
    // This has the same 25% fee as same block withdrawals and ucer receipt record set to 0 to prevent abuse of thisfunction.
    function emergencyWithdraw() public {
        UserInfo storage user = userInfo[msg.sender];
        uint256 userBRTAmount = balanceOf(msg.sender);
        uint depositTokenAmount = getDepositTokensForShares(userBRTAmount);

        require(poolInfo.depositAmount >= depositTokenAmount, "#>Bal");      //  pool.lpToken.balanceOf(address(this))
        _withdrawDepositTokens(depositTokenAmount);
        _burn(msg.sender, userBRTAmount);
        // Reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = depositTokenAmount*(75)/(100);
        uint256 devToSend = depositTokenAmount - amountToSend;  //25% penalty
        user.receiptAmount = 0;
        user.rewardDebt = 0;
        poolInfo.depositAmount -= depositTokenAmount;
        poolInfo.lpToken.safeTransfer(address(msg.sender), amountToSend);
        poolInfo.lpToken.safeTransfer(address(devaddr), devToSend);

        emit EmergencyWithdraw(msg.sender, bavaPid, amountToSend, devToSend);
    }
 
    // Restake LP token to 3rd party restaking farm
    function _stakeDepositTokens(uint amount) private {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;
        require(amount > 0, "#<0");
        _getReinvestReward();

        poolRestaking.pngStakingContract.stake(amount);
    }

    // Withdraw LP token to 3rd party restaking farm
    function _withdrawDepositTokens(uint amount) private {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;
        require(amount > 0, "#<0");
        _getReinvestReward();
        uint256 depositAmount = poolRestaking.pngStakingContract.balanceOf(address(this));
        if(depositAmount >= amount) {
            poolRestaking.pngStakingContract.withdraw(amount);
        } else {
            poolRestaking.pngStakingContract.withdraw(depositAmount);
        }
    }

    // Claim LP restaking reward from 3rd party restaking contract
    function _getReinvestReward() private {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;  
        poolRestaking.pngStakingContract.getReward();
    }

    // Emergency withdraw LP token from 3rd party restaking contract
    function emergencyWithdrawDepositTokens(bool disableDeposits) external onlyOwner {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;
        poolRestaking.pngStakingContract.exit();
        if (poolInfo.deposits_enabled == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }

    function reinvest() external {
        (uint256 estimatedTotalReward, ) = checkReward();
        require(estimatedTotalReward >= MIN_TOKENS_TO_REINVEST, "#<MinInvest");

        _reinvest();
    }

    function liquidateCollateral(address userAccount, uint256 amount) external onlyAuthorized {
        _liquidateCollateral(userAccount, amount);
    }


    /**************************************** VIEW FUNCTIONS ****************************************/
    /**
     * @notice Calculate receipt tokens for a given amount of deposit tokens
     * @dev If contract is empty, use 1:1 ratio
     * @dev Could return zero shares for very low amounts of deposit tokens
     * @param amount deposit tokens
     * @return receipt tokens
     */
    function getSharesForDepositTokens(uint amount) public view returns (uint) {
        if (totalSupply() * poolInfo.depositAmount == 0) {
            return amount;
        }
        return (amount*totalSupply() / poolInfo.depositAmount);
    }

    /**
     * @notice Calculate deposit tokens for a given amount of receipt tokens
     * @param amount receipt tokens
     * @return deposit tokens
     */
    function getDepositTokensForShares(uint amount) public view returns (uint) {
        if (totalSupply() * poolInfo.depositAmount == 0) {
            return 0;
        }
        return (amount * poolInfo.depositAmount / totalSupply());
    }

    // View function to see pending Bavas on frontend.
    function pendingReward(address _user) external view returns (uint) {
        UserInfo storage user = userInfo[_user];
        (, , uint256 allocPoint, uint256 lastRewardBlock, uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);
        uint256 lpSupply = totalSupply();

        if (block.number > lastRewardBlock && lpSupply > 0) {
            uint256 BavaForFarmer;
            (, BavaForFarmer, , ,) = BavaMasterFarm.getPoolReward(lastRewardBlock, block.number, allocPoint);
            accBavaPerShare = accBavaPerShare+(BavaForFarmer*(1e12)/(lpSupply));
        }
        return user.receiptAmount*(accBavaPerShare)/(1e12)-(user.rewardDebt);
    }

    // View function to see pending 3rd party reward
    function checkReward() public view returns (uint, uint[] memory) {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;
        uint256 pendingRewardAmount = poolRestaking.pngStakingContract.earned(address(this));
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        uint256[] memory pendingBonusToken;

        return (pendingRewardAmount+rewardBalance, pendingBonusToken);
    }

    /**************************************** ONLY OWNER FUNCTIONS ****************************************/
    // Rescue any token function, just in case if any user not able to withdraw token from the smart contract.
    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "0Addr");
        IERC20(token).safeTransfer(_to, amount);
    }

    // Update the given pool's Bava restaking contract. Can only be called by the owner.
    function setPoolRestakingInfo(IStakingRewards _stakingPglContract, IERC20 _rewardToken, IERC20[] memory _bonusRewardTokens, bool _withUpdate) external onlyOwner {
        require(address(_stakingPglContract) != address(0) , "0Addr");
        if (_withUpdate) {
            updatePool();
        }
        poolRestakingInfo.pngStakingContract = _stakingPglContract;
        // poolRestakingInfo.restakingFarmID = _restakingFarmID;
        rewardToken = _rewardToken;
        bonusRewardTokens = _bonusRewardTokens;
    }

    function setBavaMasterFarm(IBAVAMasterFarm _BavaMasterFarm, uint256 _bavaPid) external onlyOwner {
        BavaMasterFarm = _BavaMasterFarm;
        bavaPid = _bavaPid;
    }

    function devAddrUpdate(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }

    function liqAddrUpdate(address _liqaddr) public onlyOwner {
        liqaddr = _liqaddr;
    }

	function reviseWithdraw(address _user, uint256 _block) public onlyOwner {
	   UserInfo storage user = userInfo[_user];
	   user.lastWithdrawBlock = _block;	    
	}
	
	function reviseDeposit(address _user, uint256 _block) public onlyOwner {
	   UserInfo storage user = userInfo[_user];
	   user.firstDepositBlock = _block;	    
	}

    function addAuthorized(address _toAdd) onlyOwner public {
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    /**
     * @notice Enable/disable deposits
     * @param newValue bool
     */
    function updateDepositsEnabled(bool newValue) public onlyOwner {
        require(poolInfo.deposits_enabled != newValue);
        poolInfo.deposits_enabled = newValue;
        emit DepositsEnabled(newValue);
    }

    /**************************************** ONLY AUTHORIZED FUNCTIONS ****************************************/
    // Update % lock for general users & percent for other roles
    function percentUpdate(uint _newlock) public onlyAuthorized {
       PERCENT_LOCK_BONUS_REWARD = _newlock;
    }

	function setStageStarts(uint[] memory _blockStarts) public onlyAuthorized {
        blockDeltaStartStage = _blockStarts;
    }
    
    function setStageEnds(uint[] memory _blockEnds) public onlyAuthorized {
        blockDeltaEndStage = _blockEnds;
    }
    
    function setUserFeeStage(uint[] memory _userFees) public onlyAuthorized {
        userFeeStage = _userFees;
    }

    function setDepositFee(uint _usrDepFees) public onlyAuthorized {
        userDepFee = _usrDepFees;
    }

    function setMinReinvestToken(uint _MIN_TOKENS_TO_REINVEST) public onlyAuthorized {
        MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
    }

    function setDevFeeBips(uint _DEV_FEE_BIPS) public onlyAuthorized {
        DEV_FEE_BIPS = _DEV_FEE_BIPS;
    }

    function setReinvestRewardBips(uint _REINVEST_REWARD_BIPS) public onlyAuthorized {
        REINVEST_REWARD_BIPS = _REINVEST_REWARD_BIPS;
    }


    /*********************** Autocompound Strategy ******************
    * Swap all reward tokens to WAVAX and swap half/half WAVAX token to both LP  token0 & token1, Add liquidity to LP token
    ****************************************/
    function _reinvest() private {
        PoolRestakingInfo storage poolRestaking = poolRestakingInfo;
        _getReinvestReward();
        uint liquidity = _calculateReward();
        if (liquidity > 0) {
            poolRestaking.pngStakingContract.stake(liquidity);
            poolInfo.depositAmount += liquidity;
        }
    }

    function _calculateReward() private returns (uint) {
        uint256 devFee;
        uint256 reinvestFee;
        uint256 rewardAmount = rewardToken.balanceOf(address(this));

        uint pathLength = 2;
        address[] memory path = new address[](pathLength);
        uint256 avaxAmount;

        path[0] = address(rewardToken);
        path[1] = address(WAVAX);

        if (rewardAmount > 0) {
            _convertExactTokentoToken(path, rewardAmount * (DEV_FEE_BIPS + REINVEST_REWARD_BIPS)/BIPS_DIVISOR);
            avaxAmount = WAVAX.balanceOf(address(this));
            devFee = avaxAmount*(DEV_FEE_BIPS)/(DEV_FEE_BIPS + REINVEST_REWARD_BIPS);
            if (devFee > 0) {
                IERC20(address(WAVAX)).safeTransfer(devaddr, devFee);
            }
            reinvestFee = avaxAmount - devFee;
            if (reinvestFee > 0) {
                IERC20(address(WAVAX)).safeTransfer(msg.sender, reinvestFee);
            }
        }
        uint256 remainingRewardAmount = rewardToken.balanceOf(address(this));
        return (remainingRewardAmount);
    }

    // Liquidate user collateral when user LP token value lower than user borrowed fund.
    function _liquidateCollateral(address userAccount, uint256 amount) private {
        UserInfo storage user = userInfo[userAccount];
        uint depositTokenAmount = getDepositTokensForShares(amount);
        updatePool();
        _harvest(userAccount);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);
       
        require(poolInfo.depositAmount >= depositTokenAmount, "#>Bal");
        _burn(msg.sender, amount);
        _withdrawDepositTokens(depositTokenAmount);
        // Reordered from Sushi function to prevent risk of reentrancy
        user.receiptAmount -= amount;
        user.rewardDebt = user.receiptAmount * (accBavaPerShare) / (1e12);
        poolInfo.depositAmount -= depositTokenAmount;

        uint liquidateAmount = _convertTokentoUSDCE(depositTokenAmount);

        USDCE.safeTransfer(address(liqaddr), liquidateAmount);
        emit Liquidate(userAccount, amount);
    }

    function _convertTokentoUSDCE(uint amount) private returns (uint) {

        // swap tokenA to USDC
        address[] memory path;
        uint pathLength = 3;
        path = new address[](pathLength);
        path[0] = address(poolInfo.lpToken);
        path[1] = address(WAVAX);
        path[2] = address(USDCE);
        
        uint amountUSDCE = _convertExactTokentoToken(path, amount);
        
        return amountUSDCE;
    }

    function _convertExactTokentoToken(address[] memory path, uint amount) private returns (uint) {
        uint[] memory amountsOutToken = router.getAmountsOut(amount, path);
        uint amountOutToken = amountsOutToken[amountsOutToken.length - 1];
        uint[] memory amountOut = router.swapExactTokensForTokens(amount, amountOutToken, path, address(this), block.timestamp+1200);
        uint swapAmount = amountOut[amountOut.length - 1];

        return swapAmount;
    }
}
