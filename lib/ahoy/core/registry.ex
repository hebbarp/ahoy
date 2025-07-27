defmodule Ahoy.Core.Registry do
  use GenServer
  require Logger

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register_user(username, node \\ Node.self()) do
    GenServer.call(__MODULE__, {:register_user, username, node})
  end

  def unregister_user(username) do
    GenServer.call(__MODULE__, {:unregister_user, username})
  end

  def join_channel(username, channel) do
    GenServer.call(__MODULE__, {:join_channel, username, channel})
  end

  def leave_channel(username, channel) do
    GenServer.call(__MODULE__, {:leave_channel, username, channel})
  end

  def get_users() do
    GenServer.call(__MODULE__, :get_users)
  end

  def get_channel_users(channel) do
    GenServer.call(__MODULE__, {:get_channel_users, channel})
  end

  # Server callbacks
  @impl true
  def init(_args) do
    # Monitor node connections/disconnections
    :net_kernel.monitor_nodes(true)
    
    state = %{
      users: %{},        # %{username => %{node: node, channels: [channels]}}
      channels: %{}      # %{channel => [usernames]}
    }
    
    Logger.info("Registry started on #{Node.self()}")
    {:ok, state}
  end

  @impl true
  def handle_call({:register_user, username, node}, _from, state) do
    new_users = Map.put(state.users, username, %{node: node, channels: []})
    new_state = %{state | users: new_users}
    
    # Broadcast to other nodes
    broadcast_to_nodes({:user_online, username, node})
    
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister_user, username}, _from, state) do
    case Map.get(state.users, username) do
      nil -> {:reply, :ok, state}
      user ->
        # Remove from all channels
        new_channels = remove_user_from_all_channels(state.channels, username)
        new_users = Map.delete(state.users, username)
        new_state = %{state | users: new_users, channels: new_channels}
        
        # Broadcast to other nodes
        broadcast_to_nodes({:user_offline, username})
        
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:join_channel, username, channel}, _from, state) do
    case Map.get(state.users, username) do
      nil -> {:reply, {:error, :user_not_found}, state}
      user ->
        # Add to user's channels
        updated_user = %{user | channels: [channel | user.channels] |> Enum.uniq()}
        new_users = Map.put(state.users, username, updated_user)
        
        # Add to channel's users
        channel_users = Map.get(state.channels, channel, [])
        new_channels = Map.put(state.channels, channel, [username | channel_users] |> Enum.uniq())
        
        new_state = %{state | users: new_users, channels: new_channels}
        
        # Broadcast to other nodes
        broadcast_to_nodes({:join_channel, username, channel})
        
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:leave_channel, username, channel}, _from, state) do
    # Remove from user's channels
    new_users = case Map.get(state.users, username) do
      nil -> state.users
      user -> 
        updated_user = %{user | channels: List.delete(user.channels, channel)}
        Map.put(state.users, username, updated_user)
    end
    
    # Remove from channel's users
    new_channels = case Map.get(state.channels, channel) do
      nil -> state.channels
      users -> Map.put(state.channels, channel, List.delete(users, username))
    end
    
    new_state = %{state | users: new_users, channels: new_channels}
    
    # Broadcast to other nodes
    broadcast_to_nodes({:leave_channel, username, channel})
    
    {:reply, :ok, new_state}
  end

  def handle_call(:get_users, _from, state) do
    {:reply, state.users, state}
  end

  def handle_call({:get_channel_users, channel}, _from, state) do
    users = Map.get(state.channels, channel, [])
    {:reply, users, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node connected: #{node}")
    
    # Send all existing users to the newly connected node
    state.users
    |> Enum.each(fn {username, user_info} ->
      send({__MODULE__, node}, {:user_online, username, user_info.node})
      
      # Also send channel memberships
      user_info.channels
      |> Enum.each(fn channel ->
        send({__MODULE__, node}, {:join_channel, username, channel})
      end)
    end)
    
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("Node disconnected: #{node}")
    # Remove users from disconnected node
    new_users = state.users
    |> Enum.filter(fn {_username, user} -> user.node != node end)
    |> Map.new()
    
    new_state = %{state | users: new_users}
    {:noreply, new_state}
  end

  # Handle messages from other nodes
  def handle_info({:user_online, username, node}, state) do
    new_users = Map.put(state.users, username, %{node: node, channels: []})
    {:noreply, %{state | users: new_users}}
  end

  def handle_info({:user_offline, username}, state) do
    new_users = Map.delete(state.users, username)
    new_channels = remove_user_from_all_channels(state.channels, username)
    {:noreply, %{state | users: new_users, channels: new_channels}}
  end

  def handle_info({:join_channel, username, channel}, state) do
    # Update from remote node
    case Map.get(state.users, username) do
      nil -> {:noreply, state}
      user ->
        updated_user = %{user | channels: [channel | user.channels] |> Enum.uniq()}
        new_users = Map.put(state.users, username, updated_user)
        
        channel_users = Map.get(state.channels, channel, [])
        new_channels = Map.put(state.channels, channel, [username | channel_users] |> Enum.uniq())
        
        {:noreply, %{state | users: new_users, channels: new_channels}}
    end
  end

  def handle_info({:leave_channel, username, channel}, state) do
    # Update from remote node
    new_users = case Map.get(state.users, username) do
      nil -> state.users
      user -> 
        updated_user = %{user | channels: List.delete(user.channels, channel)}
        Map.put(state.users, username, updated_user)
    end
    
    new_channels = case Map.get(state.channels, channel) do
      nil -> state.channels
      users -> Map.put(state.channels, channel, List.delete(users, username))
    end
    
    {:noreply, %{state | users: new_users, channels: new_channels}}
  end

  def handle_info(:request_users, state) do
    # Manual sync request - broadcast all users to all nodes
    state.users
    |> Enum.each(fn {username, user_info} ->
      broadcast_to_nodes({:user_online, username, user_info.node})
      
      # Also send channel memberships
      user_info.channels
      |> Enum.each(fn channel ->
        broadcast_to_nodes({:join_channel, username, channel})
      end)
    end)
    
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Registry received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions
  defp broadcast_to_nodes(message) do
    Node.list()
    |> Enum.each(fn node ->
      send({__MODULE__, node}, message)
    end)
  end

  defp remove_user_from_all_channels(channels, username) do
    channels
    |> Enum.map(fn {channel, users} ->
      {channel, List.delete(users, username)}
    end)
    |> Map.new()
  end
end