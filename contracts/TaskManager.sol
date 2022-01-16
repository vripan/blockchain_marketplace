// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "./MarketplaceEntities.sol";
import "./CategoryManager.sol";
import "./RoleManager.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TaskManager
{
    CategoryManager categoryManager;
    RoleManager roleManager;
    ERC20 internal token;

    uint internal tasksCount;
    uint internal nextTaskId;
    
    mapping(uint => MarketplaceEntities.TaskDataExtended) internal tasks;

    uint constant TASK_NO_FREELANCERS_TIMEOUT_SECONDS = 10;
    uint constant TASK_NO_EVALUATOR_TIMEOUT_SECONDS = 10;

    modifier restrictedTo(RoleManager.Role role)
    {
        require(roleManager.getRole(msg.sender) == role, "operation restricted for that role");
        _;
    }

    modifier taskInState(uint taskId, MarketplaceEntities.TaskState state)
    {
        // if task id is invalid (`taskId < nextTaskId`) then 
        // the state will be `TaskState.Unknown`

        require(tasks[taskId].state == state, "invalid");
        _;
    }

    modifier restrictedToTaskManager(uint taskId)
    {
        require(tasks[taskId].manager == msg.sender, "invalid");
        _;
    }

    constructor(address categoryManager_, address roleManager_, address token_)
    {
        categoryManager = CategoryManager(categoryManager_);
        roleManager = RoleManager(roleManager_);
        token = ERC20(token_);

        tasksCount = 0;
        nextTaskId = 0;
    }
    
    /**
    * @dev Add task to manager
    * @param _task External task data
    */
    function addTask(MarketplaceEntities.TaskData calldata _task)
        public
        restrictedTo(RoleManager.Role.Manager)
        returns (uint)
    {
        require(bytes(_task.description).length > 0, "E01");
        require(_task.rewardFreelancer > 0, "E02");
        require(_task.rewardEvaluator > 0, "E03");
        require(categoryManager.isValidCategoryId(_task.category), "E04");
        
        uint taskId = nextTaskId;
        MarketplaceEntities.TaskDataExtended storage taskEx = tasks[taskId];
        
        taskEx.data = _task;
        taskEx.manager = msg.sender;
        taskEx.state = MarketplaceEntities.TaskState.NotFounded;
        taskEx.readyTimestamp = 0;

        nextTaskId += 1;
        tasksCount += 1;

        emit MarketplaceEntities.TaskAdded(msg.sender, _task.description, taskId);

        return taskId;
    }

    function removeTask(uint taskId)
        public 
        restrictedToTaskManager(taskId)
        taskInState(taskId, MarketplaceEntities.TaskState.NotFounded)
    {
        refundSponsors(taskId);
        delete tasks[taskId];
        tasksCount -= 1;

        emit MarketplaceEntities.TaskRemoved(msg.sender, taskId);
    }

    function sponsorTask(uint taskId, uint amount)
        public
        restrictedTo(RoleManager.Role.Sponsor)
        taskInState(taskId, MarketplaceEntities.TaskState.NotFounded)
    {
        require(amount > 0, "E05");
        requireSenderAllowance(amount);
    
        MarketplaceEntities.SponsorshipInfo memory sponsorship;
        sponsorship.sponsor = msg.sender;
        sponsorship.amount = amount;
        
        MarketplaceEntities.TaskDataExtended memory task = tasks[taskId];

        uint existingAmount = 0; 
        uint targetAmount = task.data.rewardFreelancer + task.data.rewardEvaluator;
        
        // check for multiple sponsorhips from the same sponsor
        for (uint i=0; i<task.sponsors.length; i++)
        {
            require(task.sponsors[i].sponsor != sponsorship.sponsor, "E08");
            existingAmount += task.sponsors[i].amount;
        }
    
        // do not receive more than target amount
        require(sponsorship.amount <= targetAmount - existingAmount, "E09");
        
        token.transferFrom(sponsorship.sponsor, address(this), sponsorship.amount);
        tasks[taskId].sponsors.push(sponsorship);

        existingAmount += sponsorship.amount;

        emit MarketplaceEntities.TaskSponsored(taskId, msg.sender, amount);

        if(existingAmount == targetAmount)
        {
            tasks[taskId].state = MarketplaceEntities.TaskState.Funded;
            emit MarketplaceEntities.TaskFunded(taskId);
        }
    }

    function withdrawSponsorship(uint taskId)
        public
        restrictedTo(RoleManager.Role.Sponsor)
        taskInState(taskId, MarketplaceEntities.TaskState.NotFounded)
    {
         MarketplaceEntities.TaskDataExtended memory task = tasks[taskId];

         for(uint i=0; i<task.sponsors.length; i++)
         {
            if(task.sponsors[i].sponsor == msg.sender)
            {
                token.transfer(task.sponsors[i].sponsor, task.sponsors[i].amount);
                
                MarketplaceEntities.deleteFromArray(tasks[taskId].sponsors, i);

                emit MarketplaceEntities.SponsorshipWidrawed(taskId, task.sponsors[i].sponsor, task.sponsors[i].amount);
                return;
            }
         }
         revert();
    }

    function linkEvaluatorToTask(uint taskId, address evaluator)
        public
        restrictedToTaskManager(taskId)
        taskInState(taskId, MarketplaceEntities.TaskState.Funded)
    {
        assert(tasks[taskId].evaluator == address(0));
        
        require(roleManager.getRole(evaluator) == RoleManager.Role.Evaluator, "E10");
        require(roleManager.getEvaluatorInfo(evaluator).data.categoryId ==  tasks[taskId].data.category, "E11");

        tasks[taskId].evaluator = evaluator;
        tasks[taskId].state = MarketplaceEntities.TaskState.Ready;
        tasks[taskId].readyTimestamp = block.timestamp + TASK_NO_FREELANCERS_TIMEOUT_SECONDS;

        emit MarketplaceEntities.TaskReady(taskId, evaluator);
    }

    function checkHireTimeout(uint taskId)
        public
        taskInState(taskId, MarketplaceEntities.TaskState.Ready)
    {
        // todo: recheck logic
        // `applyForTask` and `hireFreelancer` should success if the timeout is over?

        require(tasks[taskId].readyTimestamp >= block.timestamp, "E12");
        require(tasks[taskId].freelancers.length == 0, "E13");

        refundSponsors(taskId);
        tasks[taskId].state = MarketplaceEntities.TaskState.TimeoutOnHiring;
    
        emit MarketplaceEntities.TaskHiringTimeout(taskId);
    }

    function applyForTask(uint taskId)
        public
        restrictedTo(RoleManager.Role.Freelancer)
        taskInState(taskId, MarketplaceEntities.TaskState.Ready)
    {
        require(roleManager.getFreelancerInfo(msg.sender).data.categoryId = tasks[taskId].data.category, "E14");
        requireSenderAllowance(tasks[taskId].data.rewardEvaluator);
        token.transferFrom(msg.sender, address(this), tasks[taskId].data.rewardEvaluator);

        tasks[taskId].freelancers.push(msg.sender);
    }

    function hireFreelancer(uint taskId, uint freelancerIdx)
        public
        restrictedToTaskManager(taskId)
        taskInState(taskId, MarketplaceEntities.TaskState.Ready)
    {
        require(freelancerIdx < tasks[taskId].freelancers.length, "E15");

        for (uint i=0; i<tasks[taskId].freelancers.length; i++)
        {
            if( i != freelancerIdx)
            {
                token.transfer(tasks[taskId].freelancers[i], tasks[taskId].data.rewardEvaluator);
            }
        }
        
        // swap selected freelancer with the one at index 0
        address temp_address = tasks[taskId].freelancers[0];
        tasks[taskId].freelancers[0] = tasks[taskId].freelancers[freelancerIdx];
        tasks[taskId].freelancers[freelancerIdx] = temp_address;
        
        tasks[taskId].state = MarketplaceEntities.TaskState.WorkingOnIt;
    }

    function finishTask(uint taskId)
        public
        taskInState(taskId, MarketplaceEntities.TaskState.WorkingOnIt)
    {
        require(tasks[taskId].freelancers[0] == msg.sender, "E16");
        tasks[taskId].state = MarketplaceEntities.TaskState.Finished;
    }

    function reviewTask(uint taskId, bool accept_results)
        public 
        restrictedToTaskManager(taskId)
        taskInState(taskId, MarketplaceEntities.TaskState.Finished)
    {
        if (accept_results) 
        {
            uint reward = tasks[task].data.rewardEvaluator * 2 + tasks[task].data.rewardFreelancer;
            address freelancer = tasks[taskId].freelancers[0];
                        
            roleManager.updateFreelancerReputation(freelancer, true);
            token.transfer(freelancer, reward);

            tasks[taskId].state = MarketplaceEntities.TaskState.Accepted;            
        }
        else 
        {
            tasks[taskId].state = MarketplaceEntities.TaskState.WaitingForEvaluation;
        }
    }

    function reviewAsEvaluator(uint taskId, bool accept_result)
        public
        taskInState(taskId, MarketplaceEntities.TaskState.WaitingForEvaluation)
    {
        require(tasks[taskId].evaluator == msg.sender, "E17");

        address freelancer = tasks[taskId].freelancers[0];
        address evaluator = tasks[taskId].evaluator;

        if (accept_result)
        {

            roleManager.updateFreelancerReputation(freelancer, true);
            token.transfer(freelancer, tasks[task].data.rewardEvaluator + tasks[task].data.rewardFreelancer);
            token.transfer(evaluator, tasks[task].data.rewardEvaluator);

            tasks[taskId].state = MarketplaceEntities.TaskState.AcceptedByEvaluator;
        } else 
        {
            roleManager.updateFreelancerReputation(freelancer, false);
            refundSponsors(taskId);
            token.transfer(evaluator, tasks[task].data.rewardEvaluator);
            
            tasks[taskId].state = MarketplaceEntities.TaskState.RejectedByEvaluator;
        }
    }
        

    function refundSponsors(uint taskId)
        internal
    {
        // todo: should keep sponsors list as history?

        while(tasks[taskId].sponsors.length != 0)
        {
            uint idx = tasks[taskId].sponsors.length - 1;
            token.transfer(tasks[taskId].sponsors[idx].sponsor, tasks[taskId].sponsors[idx].amount);
            tasks[taskId].sponsors.pop();
        }
    }

    function requireSenderAllowance(uint amount)
        internal
    {
        uint amountAllowed = token.allowance(msg.sender, address(this));
        uint senderBalance = token.balanceOf(msg.sender);
        require(amountAllowed <= senderBalance, "E06");
        require(amount <= amountAllowed, "E07");
    }

    function getTasksCount() 
        public 
        view
        returns(uint)
    {
        return tasksCount;
    }
}