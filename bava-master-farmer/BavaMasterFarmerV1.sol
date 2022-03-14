// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Ownable.sol";

interface IBavaToken {
    function transfer(address to, uint tokens) external returns (bool success);

    function mint(address to, uint tokens) external;

    function balanceOf(address tokenOwner) external view returns (uint balance);

    function cap() external view returns (uint capSuppply);

    function totalSupply() external view returns (uint _totalSupply);

    function lock(address _holder, uint256 _amount) external;
}

// BavaMasterFarmer is the master of Bava. He can make Bava and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Bava is sufficiently
// distributed and the community can show to govern itself.
//
contract BavaMasterFarmerV1 is Ownable, Authorizable {
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;             // How many LP tokens the user has provided.
        uint256 rewardDebt;         // Reward debt. See explanation below.
        uint256 rewardDebtAtBlock;  // the last block user stake
		uint256 lastWithdrawBlock;  // the last block a user withdrew at.
		uint256 firstDepositBlock;  // the first block a user deposited at.
		uint256 blockdelta;         // time passed since withdrawals
		uint256 lastDepositBlock;   // the last block a user deposited at.
        
        // We do some fancy math here. Basically, any point in time, the amount of Bavas
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accBavaPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accBavaPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;             // Address of LP token contract.
        uint256 allocPoint;         // How many allocation points assigned to this pool. Bavas to distribute per block.
        uint256 lastRewardBlock;    // Last block number that Bavas distribution occurs.
        uint256 accBavaPerShare;    // Accumulated Bavas per share, times 1e12. See below.
        uint256 depositAmount;      // Total deposit amount
        bool deposits_enabled;
    }

    // The Bava TOKEN!
    IBavaToken public Bava;
    //An ETH/USDC Oracle (Chainlink)
    address public usdOracle;
    // Developer/Employee address.
    address public devaddr;
	// Future Treasury address
	address public futureTreasuryaddr;
	// Advisor Address
	address public advisoraddr;
	// Founder Reward
	address public founderaddr;
    // Bava tokens created per block.
    uint256 public REWARD_PER_BLOCK;
    // Bonus muliplier for early Bava makers.
    uint256[] public REWARD_MULTIPLIER;
    uint256[] public HALVING_AT_BLOCK; // init in constructor function
    uint256[] public blockDeltaStartStage;
    uint256[] public blockDeltaEndStage;
    uint256[] public userFeeStage;
    uint256 public FINISH_BONUS_AT_BLOCK;
    uint256 public userDepFee;
    uint256 constant internal MAX_UINT = type(uint256).max;

    // The block number when Bava mining starts.
    uint256 public START_BLOCK;

    uint256 public PERCENT_LOCK_BONUS_REWARD;   // lock xx% of bounus reward in 3 year
    uint256 public PERCENT_FOR_DEV;             // Dev bounties + Employees
	uint256 public PERCENT_FOR_FT;              // Future Treasury fund
	uint256 public PERCENT_FOR_ADR;             // Advisor fund
	uint256 public PERCENT_FOR_FOUNDERS;        // founders fund

    PoolInfo[] public poolInfo;                                             // Info of each pool.
    mapping(address => uint256) public poolId1;                             // poolId1 count from 1, subtraction 1 before using with poolInfo
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;     // Info of each user that stakes LP tokens. pid => user address => info
    uint256 public totalAllocPoint = 0;                                     // Total allocation points. Must be the sum of all allocation points in all pools.

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 devAmount);
    event SendBavaReward(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockAmount);
    event DepositsEnabled(uint pid, bool newValue);

    constructor(
        IBavaToken _IBava,
        address _devaddr,
		address _futureTreasuryaddr,
		address _advisoraddr,
		address _founderaddr,
        uint256 _userDepFee,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage
    ) {
        Bava = _IBava;
        devaddr = _devaddr;
		futureTreasuryaddr = _futureTreasuryaddr;
		advisoraddr = _advisoraddr;
		founderaddr = _founderaddr;
	    userDepFee = _userDepFee;
	    blockDeltaStartStage = _blockDeltaStartStage;
	    blockDeltaEndStage = _blockDeltaEndStage;
	    userFeeStage = _userFeeStage;
    }

    function initPool(uint256 _rewardPerBlock, uint256 _startBlock,uint256 _halvingAfterBlock) external onlyOwner {
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtBlock = _halvingAfterBlock*(i + 1)+(_startBlock);
            HALVING_AT_BLOCK.push(halvingAtBlock);
        }
        FINISH_BONUS_AT_BLOCK = _halvingAfterBlock*(REWARD_MULTIPLIER.length - 1)+(_startBlock);
        HALVING_AT_BLOCK.push(type(uint256).max);
    }  

    // Add a new lp to the pool. Can only be called by the owner. Support LP from panglolin miniChef, PNG single assest staking contract and traderJOe masterChef
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner {        
        require(poolId1[address(_lpToken)] == 0, "lp is in pool");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > START_BLOCK ? block.number : START_BLOCK;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolId1[address(_lpToken)] = poolInfo.length + 1;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accBavaPerShare: 0,
            depositAmount: 0,
            deposits_enabled: true
        }));
    }

    // Update the given pool's Bava allocation point. Can only be called by the owner.
    function set(uint256 _pid, IERC20 _lpToken, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint-(poolInfo[_pid].allocPoint)+(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].lpToken = _lpToken;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 BavaForDev;
        uint256 BavaForFarmer;
		uint256 BavaForFT;
		uint256 BavaForAdr;
		uint256 BavaForFounders;
        (BavaForDev, BavaForFarmer, BavaForFT, BavaForAdr, BavaForFounders) = getPoolReward(pool.lastRewardBlock, block.number, pool.allocPoint);
        Bava.mint(address(this), BavaForFarmer);
        pool.accBavaPerShare = pool.accBavaPerShare+(BavaForFarmer*(1e12)/(lpSupply));
        pool.lastRewardBlock = block.number;
        if (BavaForDev > 0) {
            Bava.mint(address(devaddr), BavaForDev);
            //Dev fund has xx% locked during the starting bonus period. After which locked funds drip out linearly each block over 3 years.
            Bava.lock(address(devaddr), BavaForDev*(75)/(100));            
        }
		if (BavaForFT > 0) {
            Bava.mint(futureTreasuryaddr, BavaForFT);
			//FT + Partnership fund has only xx% locked over time as most of it is needed early on for incentives and listings. The locked amount will drip out linearly each block after the bonus period.
            Bava.lock(address(futureTreasuryaddr), BavaForFT*(45)/(100));            
        }
		if (BavaForAdr > 0) {
            Bava.mint(advisoraddr, BavaForAdr);
			//Advisor Fund has xx% locked during bonus period and then drips out linearly over 3 years.
            Bava.lock(address(advisoraddr), BavaForAdr*(85)/(100));
        }
		if (BavaForFounders > 0) {
            Bava.mint(founderaddr, BavaForFounders);
			//The Founders reward has xx% of their funds locked during the bonus period which then drip out linearly per block over 3 years.
            Bava.lock(address(founderaddr), BavaForFounders*(95)/(100));
        }
    }

    // |--------------------------------------|
    // [20, 30, 40, 50, 60, 70, 80, 99999999]
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 0;

        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];

            if (_to <= endBlock) {
                uint256 m = (_to-_from)*(REWARD_MULTIPLIER[i]);
                return result+(m);
            }

            if (_from < endBlock) {
                uint256 m = (endBlock-_from)*(REWARD_MULTIPLIER[i]);
                _from = endBlock;
                result = result+(m);
            }
        }
        return result;
    }

    function getPoolReward(uint256 _from, uint256 _to, uint256 _allocPoint) public view returns (uint256 forDev, uint256 forFarmer, uint256 forFT, uint256 forAdr, uint256 forFounders) {
        uint256 multiplier = getMultiplier(_from, _to);
        uint256 amount = multiplier*(REWARD_PER_BLOCK)*(_allocPoint)/(totalAllocPoint);
        uint256 BavaCanMint = Bava.cap()-(Bava.totalSupply());

        if (BavaCanMint < amount) {
            forDev = 0;
			forFarmer = BavaCanMint;
			forFT = 0;
			forAdr = 0;
			forFounders = 0;
        }
        else {
            forDev = amount*(PERCENT_FOR_DEV)/(100000);
			forFarmer = amount;
			forFT = amount*(PERCENT_FOR_FT)/(100);
			forAdr = amount*(PERCENT_FOR_ADR)/(10000);
			forFounders = amount*(PERCENT_FOR_FOUNDERS)/(100000);
        }
    }

    function claimReward(uint256 _pid) public {
        updatePool(_pid);
        _harvest(_pid);
    }

    // lock 95% of reward
    function _harvest(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.amount > 0) {
            uint256 pending = user.amount*(pool.accBavaPerShare)/(1e12)-(user.rewardDebt);
            uint256 masterBal = Bava.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }
            
            if(pending > 0) {
                safeBavaTransfer(msg.sender, pending);
                uint256 lockAmount = 0;
                lockAmount = pending*(PERCENT_LOCK_BONUS_REWARD)/(100);
                Bava.lock(msg.sender, lockAmount);

                user.rewardDebtAtBlock = block.number;

                emit SendBavaReward(msg.sender, _pid, pending, lockAmount);
            }
            user.rewardDebt = user.amount*(pool.accBavaPerShare)/(1e12);
        }
    }
    
    // Deposit LP tokens to BavaMasterFarmer for $Bava allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require(_amount > 0, "amount < 0");

        PoolInfo storage pool = poolInfo[_pid];
        require(pool.deposits_enabled == true, "deposit false");
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserInfo storage devr = userInfo[_pid][devaddr];
        
        updatePool(_pid);
        _harvest(_pid);
        
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        pool.depositAmount += _amount;

        if (user.amount == 0) {
            user.rewardDebtAtBlock = block.number;
        }

        uint256 userAmount = _amount - _amount*(userDepFee)/(10000);
        user.amount += userAmount;
        user.rewardDebt = user.amount*(pool.accBavaPerShare)/(1e12);
        devr.amount += (_amount - userAmount);
        devr.rewardDebt = devr.amount*(pool.accBavaPerShare)/(1e12);

        emit Deposit(msg.sender, _pid, _amount);
		if(user.firstDepositBlock > 0){
		} else {
			user.firstDepositBlock = block.number;
		}
		user.lastDepositBlock = block.number;
    }
    
  // Withdraw LP tokens from BavaMasterFarmer. 
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        uint256 lpBal = pool.lpToken.balanceOf(address(this));
        require(lpBal >= _amount, "withdraw > farmBal");
        require(user.amount >= _amount, "withdraw > stake");

        updatePool(_pid);
        _harvest(_pid);
        
        if(_amount > 0) {
            user.amount = user.amount-(_amount);
			if(user.lastWithdrawBlock > 0){
				user.blockdelta = block.number - user.lastWithdrawBlock; }
			else {
				user.blockdelta = block.number - user.firstDepositBlock;
			}

			if(user.blockdelta == blockDeltaStartStage[0] || block.number == user.lastDepositBlock){
				//25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                uint256 userWithdrawFee = _amount*(userFeeStage[0])/100;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[1] && user.blockdelta <= blockDeltaEndStage[0]){
				//8% fee if a user deposits and withdraws in under between same block and 59 minutes.
                uint256 userWithdrawFee = _amount*(userFeeStage[1])/100;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[2] && user.blockdelta <= blockDeltaEndStage[1]){
				//4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                uint256 userWithdrawFee = _amount*(userFeeStage[2])/100;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[3] && user.blockdelta <= blockDeltaEndStage[2]){
				//2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                uint256 userWithdrawFee = _amount*(userFeeStage[3])/100;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[4] && user.blockdelta <= blockDeltaEndStage[3]){
				//1% fee if a user deposits and withdraws after 3 days but before 5 days.
                uint256 userWithdrawFee = _amount*(userFeeStage[4])/100;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			}  else if (user.blockdelta >= blockDeltaStartStage[5] && user.blockdelta <= blockDeltaEndStage[4]){
				//0.5% fee if a user deposits and withdraws if the user withdraws after 5 days but before 2 weeks.
                uint256 userWithdrawFee = _amount*(userFeeStage[5])/1000;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta >= blockDeltaStartStage[6] && user.blockdelta <= blockDeltaEndStage[5]){
				//0.25% fee if a user deposits and withdraws after 2 weeks.
                uint256 userWithdrawFee = _amount*(userFeeStage[6])/10000;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			} else if (user.blockdelta > blockDeltaStartStage[7]) {
				//0.1% fee if a user deposits and withdraws after 4 weeks.
                uint256 userWithdrawFee = _amount*(userFeeStage[7])/10000;
                pool.depositAmount -= _amount;
				pool.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
				pool.lpToken.safeTransfer(address(devaddr), _amount-userWithdrawFee);
			}
		user.rewardDebt = user.amount*(pool.accBavaPerShare)/(1e12);

        emit Withdraw(msg.sender, _pid, _amount);
		user.lastWithdrawBlock = block.number;
			}
        }

    // Withdraw without caring about rewards. EMERGENCY ONLY. This has the same 25% fee as same block withdrawals to prevent abuse of thisfunction.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 lpBal = pool.lpToken.balanceOf(address(this));
        require(lpBal >= user.amount, "withdraw > farmBal");

        //reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = user.amount*(75)/(100);
        uint256 devAmountToSend = user.amount - amountToSend;
        
        user.amount = 0;
        user.rewardDebt = 0;
        pool.depositAmount = pool.depositAmount - amountToSend - devAmountToSend;

        pool.lpToken.safeTransfer(address(msg.sender), amountToSend);
        pool.lpToken.safeTransfer(address(devaddr), devAmountToSend);

        emit EmergencyWithdraw(msg.sender, _pid, amountToSend, devAmountToSend);
    }

    /**
     * @notice Enable/disable deposits
     * @param newValue bool
     */
    function updateDepositsEnabled(uint _pid, bool newValue) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        require(pool.deposits_enabled != newValue);
        pool.deposits_enabled = newValue;
        emit DepositsEnabled(_pid, newValue);
    } 

    // Safe Bava transfer function, just in case if rounding error causes pool to not have enough Bavas.
    function safeBavaTransfer(address _to, uint256 _amount) private {
        uint256 BavaBal = Bava.balanceOf(address(this));
        if (_amount > BavaBal) {
            Bava.transfer(_to, BavaBal);
        } else {
            Bava.transfer(_to, _amount);
        }
    }

    // Rescue any token function, just in case if any user not able to withdraw token from the smart contract.
    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "send to the zero address");
        IERC20(token).safeTransfer(_to, amount);
    }

    /****** ONLY AUTHORIZED FUNCTIONS ******/
    // Update smart contract general variable functions
    // Update dev address by the previous dev.
    function addrUpdate(address _devaddr, address _newFT, address _newAdr, address _newFounder) public onlyAuthorized {
        devaddr = _devaddr;
        futureTreasuryaddr = _newFT;
        advisoraddr = _newAdr;
        founderaddr = _newFounder;
    }

    // Update % lock for general users & percent for other roles
    function percentUpdate(uint _newlock, uint _newdev, uint _newft, uint _newadr, uint _newfounder) public onlyAuthorized {
       PERCENT_LOCK_BONUS_REWARD = _newlock;
       PERCENT_FOR_DEV = _newdev;
       PERCENT_FOR_FT = _newft;
       PERCENT_FOR_ADR = _newadr;
       PERCENT_FOR_FOUNDERS = _newfounder;
    }

    // Update Finish Bonus Block
    function bonusFinishUpdate(uint256 _newFinish) public onlyAuthorized {
        FINISH_BONUS_AT_BLOCK = _newFinish;
    }
    
    // Update Halving At Block
    function halvingUpdate(uint256[] memory _newHalving) public onlyAuthorized {
        HALVING_AT_BLOCK = _newHalving;
    }
    
    // Update Reward Per Block
    function rewardUpdate(uint256 _newReward) public onlyAuthorized {
       REWARD_PER_BLOCK = _newReward;
    }
    
    // Update Rewards Mulitplier Array
    function rewardMulUpdate(uint256[] memory _newMulReward) public onlyAuthorized {
       REWARD_MULTIPLIER = _newMulReward;
    }
    
    // Update START_BLOCK
    function starblockUpdate(uint _newstarblock) public onlyAuthorized {
       START_BLOCK = _newstarblock;
    }

	function setStageStarts(uint[] memory _blockStarts) public onlyAuthorized() {
        blockDeltaStartStage = _blockStarts;
    }
    
    function setStageEnds(uint[] memory _blockEnds) public onlyAuthorized() {
        blockDeltaEndStage = _blockEnds;
    }
    
    function setUserFeeStage(uint[] memory _userFees) public onlyAuthorized() {
        userFeeStage = _userFees;
    }
    
    function setDevDepFee(uint _usrDepFees) public onlyAuthorized() {
        userDepFee = _usrDepFees;
        // devDepFee = _devDepFees;
    }
	
    // Update smart contract specific pool user variable function 
	function reviseWithdraw(uint _pid, address _user, uint256 _block) public onlyAuthorized() {
	   UserInfo storage user = userInfo[_pid][_user];
	   user.lastWithdrawBlock = _block;	    
	}
	
	function reviseDeposit(uint _pid, address _user, uint256 _block) public onlyAuthorized() {
	   UserInfo storage user = userInfo[_pid][_user];
	   user.firstDepositBlock = _block;	    
	}

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // View function to see pending Bavas on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accBavaPerShare = pool.accBavaPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));

        if (block.number > pool.lastRewardBlock && lpSupply > 0) {
            uint256 BavaForFarmer;
            (, BavaForFarmer, , ,) = getPoolReward(pool.lastRewardBlock, block.number, pool.allocPoint);
            accBavaPerShare = accBavaPerShare+(BavaForFarmer*(1e12)/(lpSupply));
        }
        return user.amount*(accBavaPerShare)/(1e12)-(user.rewardDebt);
    }
}
