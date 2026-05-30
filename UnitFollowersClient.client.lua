-- Connected Discord-GitHub
-- StarterPlayerScripts/UnitFollowersClient.client.lua
-- Client-side unit follower system for Roblox.
-- This script visually spawns equipped units around the local player, keeps them non-collidable,
-- follows terrain using raycasts, plays movement animations, and moves units into attack positions
-- when the server sends a target enemy through RemoteEvents.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local player = Players.LocalPlayer

local UnitsFolder = ReplicatedStorage:WaitForChild("Units")
local RemotesFolder = ReplicatedStorage:WaitForChild("UnitRemotes")
local GetUnitsFunction = RemotesFolder:WaitForChild("GetUnits")
local UnitsUpdatedEvent = RemotesFolder:WaitForChild("UnitsUpdated")

local EnemyRemotes = ReplicatedStorage:WaitForChild("EnemyRemotes")
local TargetEnemyEvent = EnemyRemotes:WaitForChild("TargetEnemy")
local ClearEnemyTargetEvent = EnemyRemotes:WaitForChild("ClearEnemyTarget")

local IdleAnimationObject = script:WaitForChild("Idle")
local RunAnimationObject = script:WaitForChild("Run")
local JumpAnimationObject = script:WaitForChild("Jump")
local PunchAnimationObject = script:WaitForChild("Punch1")

-- This folder name is unique for each local player.
-- That prevents old follower clones from stacking if the player respawns or data refreshes.
local FOLLOW_FOLDER_NAME = "ClientUnitFollowers_" .. tostring(player.UserId)
local OLD_SHARED_FOLDER_NAME = "ClientUnitFollowers"

local NO_COLLISION_GROUP = "ClientUnitFollowersNoCollision"

local FOLLOW_SPEED = 14
local ATTACK_RUN_SPEED = 22
local ROTATE_SPEED = 12

local JUMP_HEIGHT = 4
local JUMP_TIME = 0.45

local UNIT_ATTACK_DISTANCE = 6.2

local GROUND_RAY_HEIGHT = 45
local GROUND_RAY_DEPTH = 180
local GROUND_OFFSET_EXTRA = 0.05

-- These CFrame offsets control where each equipped unit stands behind the player.
-- They are multiplied by the player's HumanoidRootPart CFrame, so they rotate with the character.
local SLOT_OFFSETS = {
	[1] = CFrame.new(-4.2, 0, 4.8),
	[2] = CFrame.new(4.2, 0, 4.8),
	[3] = CFrame.new(0, 0, 6.5),
	[4] = CFrame.new(-6.4, 0, 8.2),
	[5] = CFrame.new(6.4, 0, 8.2),
}

-- These offsets place units around the enemy when attacking.
-- They are multiplied by the enemy root CFrame, so the followers surround the enemy correctly.
local ENEMY_ATTACK_OFFSETS = {
	[1] = CFrame.new(-3.2, 0, -3),
	[2] = CFrame.new(3.2, 0, -3),
	[3] = CFrame.new(0, 0, -4.5),
	[4] = CFrame.new(-4.5, 0, 0),
	[5] = CFrame.new(4.5, 0, 0),
}

local activeFollowers = {}
local currentData = nil
local jumpingUntil = 0
local currentEnemy = nil
local refreshToken = 0

local function setupCollisionGroup()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(NO_COLLISION_GROUP)
	end)

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(NO_COLLISION_GROUP, "Default", false)
	end)

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(NO_COLLISION_GROUP, NO_COLLISION_GROUP, false)
	end)
end

setupCollisionGroup()

local function clearOldClientFollowers()
	local oldShared = workspace:FindFirstChild(OLD_SHARED_FOLDER_NAME)
	if oldShared then
		oldShared:Destroy()
	end

	local ownFolder = workspace:FindFirstChild(FOLLOW_FOLDER_NAME)
	if ownFolder then
		ownFolder:Destroy()
	end
end

clearOldClientFollowers()

local function getFollowersFolder()
	local folder = workspace:FindFirstChild(FOLLOW_FOLDER_NAME)

	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLLOW_FOLDER_NAME
		folder.Parent = workspace
	end

	return folder
end

local function makePartNoCollision(part)
	if not part or not part:IsA("BasePart") then
		return
	end

	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	pcall(function()
		part.CollisionGroup = NO_COLLISION_GROUP
	end)

	part.CustomPhysicalProperties = PhysicalProperties.new(
		0.01,
		0,
		0,
		0,
		0
	)
end

local function forceModelNoCollision(model)
	if not model then
		return
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			makePartNoCollision(descendant)
		end
	end
end

local function findUnitTemplate(unitName)
	for _, rarityFolder in ipairs(UnitsFolder:GetChildren()) do
		if rarityFolder:IsA("Folder") then
			local unit = rarityFolder:FindFirstChild(unitName)

			if unit and unit:IsA("Model") then
				return unit
			end
		end
	end

	return nil
end

local function getCharacterParts()
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	return character, humanoid, root
end

local function getEnemyParts(enemy)
	if not enemy or not enemy.Parent then
		return nil, nil
	end

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local root =
		enemy:FindFirstChild("HumanoidRootPart")
		or enemy:FindFirstChild("Torso")
		or enemy:FindFirstChild("UpperTorso")

	if not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil
	end

	return humanoid, root
end

local function getRaycastIgnoreList()
	local ignoreList = {}

	local character = player.Character
	if character then
		table.insert(ignoreList, character)
	end

	local followersFolder = workspace:FindFirstChild(FOLLOW_FOLDER_NAME)
	if followersFolder then
		table.insert(ignoreList, followersFolder)
	end

	local oldShared = workspace:FindFirstChild(OLD_SHARED_FOLDER_NAME)
	if oldShared then
		table.insert(ignoreList, oldShared)
	end

	if currentEnemy then
		table.insert(ignoreList, currentEnemy)
	end

	return ignoreList
end

local function getGroundYAt(position, fallbackY)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = getRaycastIgnoreList()
	raycastParams.IgnoreWater = false

	local origin = Vector3.new(position.X, position.Y + GROUND_RAY_HEIGHT, position.Z)
	local direction = Vector3.new(0, -GROUND_RAY_DEPTH, 0)

	local result = workspace:Raycast(origin, direction, raycastParams)

	if result then
		return result.Position.Y
	end

	return fallbackY or position.Y
end

local function calculateGroundOffset(model, root)
	local boundingCFrame, boundingSize = model:GetBoundingBox()
	local bottomY = boundingCFrame.Position.Y - (boundingSize.Y / 2)
	local offset = root.Position.Y - bottomY

	if offset < 0.5 then
		offset = 2
	end

	return offset + GROUND_OFFSET_EXTRA
end

local function getGroundedPosition(position, follower, fallbackY)
	local groundY = getGroundYAt(position, fallbackY)
	local groundOffset = follower.GroundOffset or 2

	return Vector3.new(
		position.X,
		groundY + groundOffset,
		position.Z
	)
end

local function prepareUnitModel(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then
		warn(model.Name .. " needs Humanoid and HumanoidRootPart.")
		return nil, nil, nil
	end

	model.PrimaryPart = root

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			makePartNoCollision(descendant)
			descendant.Anchored = false
		end
	end

	-- Only root is anchored.
	-- This lets animations keep working while the entire model is moved with PivotTo.
	root.Anchored = true
	makePartNoCollision(root)

	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.AutoRotate = false
	humanoid.PlatformStand = false
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return humanoid, root, animator
end

local function loadAnimation(animator, animationObject, priority)
	if not animator then
		return nil
	end

	if not animationObject or not animationObject:IsA("Animation") then
		return nil
	end

	if animationObject.AnimationId == "" then
		warn(animationObject.Name .. " has no AnimationId.")
		return nil
	end

	local success, result = pcall(function()
		return animator:LoadAnimation(animationObject)
	end)

	if success and result then
		local track = result
		track.Priority = priority or Enum.AnimationPriority.Movement
		return track
	end

	warn("Could not load animation:", animationObject.Name, result)
	return nil
end

local function stopTrack(track)
	if track and track.IsPlaying then
		track:Stop(0.12)
	end
end

local function stopMovementTracks(follower)
	stopTrack(follower.IdleTrack)
	stopTrack(follower.RunTrack)
	stopTrack(follower.JumpTrack)
end

local function stopAttackTrack(follower)
	if follower.PunchTrack and follower.PunchTrack.IsPlaying then
		follower.PunchTrack:Stop(0.12)
	end
end

local function stopAllTracks(follower)
	stopMovementTracks(follower)
	stopAttackTrack(follower)
end

local function playOnly(follower, state)
	if follower.CurrentState == state then
		return
	end

	follower.CurrentState = state

	stopAllTracks(follower)

	local track = nil

	if state == "Idle" then
		track = follower.IdleTrack
	elseif state == "Run" then
		track = follower.RunTrack
	elseif state == "Jump" then
		track = follower.JumpTrack
	end

	if track then
		track.Looped = state ~= "Jump"
		track:Play(0.12)
	end
end

local function playAttackLoop(follower)
	if follower.CurrentState ~= "Attack" then
		follower.CurrentState = "Attack"
		stopMovementTracks(follower)
	end

	if follower.PunchTrack then
		follower.PunchTrack.Looped = true

		if not follower.PunchTrack.IsPlaying then
			follower.PunchTrack:Play(0.08)
		end
	end
end

local function createFollower(slot, unitData)
	local template = findUnitTemplate(unitData.UnitName)
	if not template then
		warn("Could not find unit template:", unitData.UnitName)
		return nil
	end

	local clone = template:Clone()
	clone.Name = "Follower_" .. tostring(slot) .. "_" .. tostring(unitData.UnitName)
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:SetAttribute("ClientFollower", true)
	clone.Parent = getFollowersFolder()

	local humanoid, root, animator = prepareUnitModel(clone)
	if not humanoid or not root or not animator then
		clone:Destroy()
		return nil
	end

	local follower = {
		Slot = slot,
		UnitId = unitData.UnitId,
		UnitName = unitData.UnitName,

		Model = clone,
		Humanoid = humanoid,
		Root = root,
		Animator = animator,

		IdleTrack = loadAnimation(animator, IdleAnimationObject, Enum.AnimationPriority.Idle),
		RunTrack = loadAnimation(animator, RunAnimationObject, Enum.AnimationPriority.Movement),
		JumpTrack = loadAnimation(animator, JumpAnimationObject, Enum.AnimationPriority.Action),

		PunchTrack = loadAnimation(animator, PunchAnimationObject, Enum.AnimationPriority.Action4),

		CurrentState = nil,
		GroundOffset = 2,
	}

	local _, _, playerRoot = getCharacterParts()
	if playerRoot then
		local startCFrame = playerRoot.CFrame * (SLOT_OFFSETS[slot] or SLOT_OFFSETS[3])
		clone:PivotTo(startCFrame)

		task.wait()

		forceModelNoCollision(clone)

		follower.GroundOffset = calculateGroundOffset(clone, root)

		local groundedPosition = getGroundedPosition(startCFrame.Position, follower, playerRoot.Position.Y)
		clone:PivotTo(CFrame.lookAt(groundedPosition, groundedPosition + playerRoot.CFrame.LookVector))
	else
		follower.GroundOffset = calculateGroundOffset(clone, root)
	end

	playOnly(follower, "Idle")
	forceModelNoCollision(clone)

	return follower
end

local function destroyFollowers()
	for _, follower in pairs(activeFollowers) do
		if follower then
			stopAllTracks(follower)

			if follower.Model and follower.Model.Parent then
				follower.Model:Destroy()
			end
		end
	end

	table.clear(activeFollowers)

	local folder = workspace:FindFirstChild(FOLLOW_FOLDER_NAME)
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			child:Destroy()
		end
	end
end

local function getUnitById(unitId)
	if not currentData then
		return nil
	end

	for _, unitData in ipairs(currentData.Units or {}) do
		if unitData.UnitId == unitId then
			return unitData
		end
	end

	return nil
end

local function refreshFollowers()
	refreshToken += 1
	local myToken = refreshToken

	destroyFollowers()

	task.defer(function()
		if myToken ~= refreshToken then
			return
		end

		if not currentData then
			return
		end

		for slotString, unitId in pairs(currentData.Equipped or {}) do
			if myToken ~= refreshToken then
				return
			end

			local slot = tonumber(slotString)
			local unitData = getUnitById(unitId)

			if slot and unitData and slot >= 1 and slot <= 5 then
				activeFollowers[slot] = createFollower(slot, unitData)
			end
		end
	end)
end

local function setData(data)
	currentData = data
	refreshFollowers()
end

local function requestData()
	local success, data = pcall(function()
		return GetUnitsFunction:InvokeServer()
	end)

	if success and data then
		setData(data)
	else
		warn("Could not get unit data.")
	end
end

local function setupCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")

	humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Jumping then
			jumpingUntil = os.clock() + JUMP_TIME
		elseif newState == Enum.HumanoidStateType.Freefall then
			jumpingUntil = os.clock() + JUMP_TIME
		elseif newState == Enum.HumanoidStateType.Landed then
			jumpingUntil = 0
		end
	end)

	task.wait(0.5)
	refreshFollowers()
end

local function updateFollowerNormal(deltaTime, slot, follower, playerHumanoid, playerRoot)
	local moving = playerHumanoid.MoveDirection.Magnitude > 0.05
	local jumping = os.clock() < jumpingUntil

	local offset = SLOT_OFFSETS[slot] or SLOT_OFFSETS[3]
	local targetCFrame = playerRoot.CFrame * offset
	local targetPosition = getGroundedPosition(targetCFrame.Position, follower, playerRoot.Position.Y)

	if jumping then
		targetPosition += Vector3.new(0, JUMP_HEIGHT, 0)
		playOnly(follower, "Jump")
	elseif moving then
		playOnly(follower, "Run")
	else
		playOnly(follower, "Idle")
	end

	local currentCFrame = follower.Model:GetPivot()
	local currentPosition = currentCFrame.Position

	local moveAlpha = math.clamp(deltaTime * FOLLOW_SPEED, 0, 1)
	local newPosition = currentPosition:Lerp(targetPosition, moveAlpha)

	local lookDirection = playerRoot.CFrame.LookVector
	local desiredCFrame = CFrame.lookAt(newPosition, newPosition + lookDirection)

	local rotateAlpha = math.clamp(deltaTime * ROTATE_SPEED, 0, 1)
	local finalCFrame = currentCFrame:Lerp(desiredCFrame, rotateAlpha)

	follower.Model:PivotTo(finalCFrame)
	forceModelNoCollision(follower.Model)
end

local function updateFollowerAttack(deltaTime, slot, follower, enemyRoot)
	local enemyOffset = ENEMY_ATTACK_OFFSETS[slot] or ENEMY_ATTACK_OFFSETS[3]
	local targetCFrame = enemyRoot.CFrame * enemyOffset
	local targetPosition = getGroundedPosition(targetCFrame.Position, follower, enemyRoot.Position.Y)

	local currentCFrame = follower.Model:GetPivot()
	local currentPosition = currentCFrame.Position

	local distanceToEnemy = (currentPosition - enemyRoot.Position).Magnitude

	if distanceToEnemy <= UNIT_ATTACK_DISTANCE then
		playAttackLoop(follower)
	else
		playOnly(follower, "Run")
	end

	local moveAlpha = math.clamp(deltaTime * ATTACK_RUN_SPEED, 0, 1)
	local newPosition = currentPosition:Lerp(targetPosition, moveAlpha)

	local lookAtPosition = Vector3.new(enemyRoot.Position.X, newPosition.Y, enemyRoot.Position.Z)

	if (lookAtPosition - newPosition).Magnitude < 0.1 then
		lookAtPosition = newPosition + enemyRoot.CFrame.LookVector
	end

	local desiredCFrame = CFrame.lookAt(newPosition, lookAtPosition)

	local rotateAlpha = math.clamp(deltaTime * ROTATE_SPEED, 0, 1)
	local finalCFrame = currentCFrame:Lerp(desiredCFrame, rotateAlpha)

	follower.Model:PivotTo(finalCFrame)
	forceModelNoCollision(follower.Model)
end

RunService.RenderStepped:Connect(function(deltaTime)
	local _, playerHumanoid, playerRoot = getCharacterParts()
	if not playerHumanoid or not playerRoot then
		return
	end

	local enemyHumanoid, enemyRoot = getEnemyParts(currentEnemy)

	if currentEnemy and (not enemyHumanoid or not enemyRoot) then
		currentEnemy = nil
	end

	for slot, follower in pairs(activeFollowers) do
		if follower and follower.Model and follower.Model.Parent then
			if enemyHumanoid and enemyRoot then
				updateFollowerAttack(deltaTime, slot, follower, enemyRoot)
			else
				updateFollowerNormal(deltaTime, slot, follower, playerHumanoid, playerRoot)
			end
		end
	end
end)

TargetEnemyEvent.OnClientEvent:Connect(function(enemy)
	local humanoid, root = getEnemyParts(enemy)

	if humanoid and root then
		currentEnemy = enemy
	end
end)

ClearEnemyTargetEvent.OnClientEvent:Connect(function(enemy)
	if not enemy or currentEnemy == enemy then
		currentEnemy = nil

		for _, follower in pairs(activeFollowers) do
			if follower then
				follower.CurrentState = nil
				stopAttackTrack(follower)
			end
		end
	end
end)

UnitsUpdatedEvent.OnClientEvent:Connect(function(data)
	setData(data)
end)

player.CharacterAdded:Connect(setupCharacter)

if player.Character then
	setupCharacter(player.Character)
end

requestData()
