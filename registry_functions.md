# Ahoy Registry Functions Documentation

## Overview
The Registry is the core distributed state management system for Ahoy. It maintains user and channel information across all connected nodes using Erlang's distributed messaging system.

## Architecture

### State Structure
```elixir
state = %{
  users: %{},        # %{username => %{node: node, channels: [channels]}}
  channels: %{}      # %{channel => [usernames]}
}
```

### Network Monitoring
- Uses `:net_kernel.monitor_nodes(true)` to track node connections
- Automatically receives `{:nodeup, node}` and `{:nodedown, node}` messages
- Cleans up users when nodes disconnect

## Client API Functions

### User Management
- `register_user(username, node \\ Node.self())` - Register a new user
- `unregister_user(username)` - Remove user and clean up all channel memberships
- `get_users()` - Get all registered users with their node and channel info

### Channel Management  
- `join_channel(username, channel)` - Add user to a channel
- `leave_channel(username, channel)` - Remove user from a channel
- `get_channel_users(channel)` - Get list of users in a specific channel

## Server Callbacks

### Initialization
**`init/1` (lines 31-40)**
- Sets up node connection monitoring
- Initializes empty state maps for users and channels
- Logs startup message

### User Operations
**`register_user` (lines 42-50)**
- Adds user to local `users` map with node info and empty channels list
- Broadcasts `{:user_online, username, node}` to all connected nodes
- Returns `:ok` to caller

**`unregister_user` (lines 52-67)**
- Removes user from local `users` map
- Cleans up user from all channels using `remove_user_from_all_channels/2`
- Broadcasts `{:user_offline, username}` to network
- Handles case where user doesn't exist gracefully

### Channel Operations
**`join_channel` (lines 69-87)**
- Updates user's channels list (adds channel, removes duplicates)
- Updates channel's users list (adds user, removes duplicates)  
- Broadcasts `{:join_channel, username, channel}` to network
- Returns error if user not found

**`leave_channel` (lines 89-103)**
- Removes channel from user's channels list
- Removes user from channel's users list
- Broadcasts `{:leave_channel, username, channel}` to network
- Handles missing user/channel gracefully

### Query Operations
**`get_users` (lines 105-107)**
- Returns complete users map with all user info

**`get_channel_users` (lines 109-112)**
- Returns list of usernames for specific channel
- Returns empty list if channel doesn't exist

## Network Event Handlers

### Node Connection Events
**`{:nodeup, node}` (lines 112-115)**
- Logs when new node connects to cluster
- No state changes needed (remote node will sync its users)

**`{:nodedown, node}` (lines 117-124)**
- Logs when node disconnects
- Filters out all users from disconnected node
- Automatic cleanup prevents stale user data

### Inter-Node Message Handlers

**`{:user_online, username, node}` (lines 126-129)**
- Received when user registers on remote node
- Adds user to local registry with empty channels list
- Maintains consistency across all nodes

**`{:user_offline, username}` (lines 131-135)**
- Received when user unregisters on remote node  
- Removes user from local registry
- Cleans up user from all channels

**`{:join_channel, username, channel}` (lines 137-149)**
- Received when user joins channel on remote node
- Updates both user's channels list and channel's users list locally
- Ignores if user doesn't exist locally

**`{:leave_channel, username, channel}` (lines 151-164)**
- Received when user leaves channel on remote node
- Updates both user's channels list and channel's users list locally  
- Handles missing user/channel gracefully

## Private Helper Functions

### `broadcast_to_nodes/1` (lines 166-171)
**Purpose:** Send message to Registry process on all connected nodes
**How it works:**
- `Node.list()` gets all connected nodes
- Sends message to `{__MODULE__, node}` (Registry process on each node)
- Uses Erlang's distributed messaging system

### `remove_user_from_all_channels/2` (lines 173-178)
**Purpose:** Clean up user references from all channels
**How it works:**
- Maps over all channels
- Removes username from each channel's user list
- Returns updated channels map

## Message Flow Examples

### User Registration Flow
1. User calls `register_user("alice", node1)`
2. Local Registry adds alice to users map  
3. Broadcasts `{:user_online, "alice", node1}` to all nodes
4. Remote nodes receive message and add alice to their registries
5. All nodes now know alice is online

### Channel Join Flow  
1. User calls `join_channel("alice", "#general")`
2. Local Registry updates alice's channels and #general's users
3. Broadcasts `{:join_channel, "alice", "#general"}` to all nodes
4. Remote nodes update their local state to match
5. All nodes now show alice in #general

### Node Disconnect Flow
1. Node2 suddenly disconnects (network issue, crash, etc.)
2. All remaining nodes receive `{:nodedown, node2}` from `:net_kernel`
3. Each node filters out users from node2
4. Registry state is automatically cleaned up
5. No stale user data remains in the system

## Key Benefits

- **Distributed**: State replicated across all nodes
- **Eventually Consistent**: All nodes converge to same state
- **Fault Tolerant**: Automatic cleanup on node failures  
- **Real-time**: Changes broadcast immediately
- **Simple**: Clean API hides distributed complexity