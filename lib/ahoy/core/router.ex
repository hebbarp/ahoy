defmodule Ahoy.Core.Router do
  use GenServer
  require Logger

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def send_channel_message(from_user, channel, message) do
    GenServer.cast(__MODULE__, {:channel_message, from_user, channel, message})
  end

  def send_direct_message(from_user, to_user, message) do
    GenServer.cast(__MODULE__, {:direct_message, from_user, to_user, message})
  end

  def send_system_message(channel, message) do
    GenServer.cast(__MODULE__, {:system_message, channel, message})
  end

  # Server callbacks
  @impl true
  def init(_args) do
    Logger.info("Router started on #{Node.self()}")
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:channel_message, from_user, channel, message}, state) do
    # Get all users in the channel from Registry
    case Ahoy.Core.Registry.get_channel_users(channel) do
      [] ->
        Logger.warn("No users in channel #{channel}")
      
      users ->
        # Create message with timestamp
        timestamped_message = %{
          type: :channel_message,
          from: from_user,
          channel: channel,
          message: message,
          timestamp: DateTime.utc_now()
        }
        
        # Send to all users in channel (including sender for confirmation)
        deliver_to_users(users, timestamped_message)
        
        # Broadcast to other nodes
        broadcast_to_nodes({:route_message, timestamped_message, users})
        
        Logger.debug("Routed channel message from #{from_user} to #{channel}: #{length(users)} users")
    end
    
    {:noreply, state}
  end

  def handle_cast({:direct_message, from_user, to_user, message}, state) do
    # Check if target user exists
    users = Ahoy.Core.Registry.get_users()
    
    case Map.get(users, to_user) do
      nil ->
        # Send error back to sender
        error_message = %{
          type: :error,
          message: "User #{to_user} not found",
          timestamp: DateTime.utc_now()
        }
        deliver_to_user(from_user, error_message)
        
      target_user ->
        # Create direct message
        timestamped_message = %{
          type: :direct_message,
          from: from_user,
          to: to_user,
          message: message,
          timestamp: DateTime.utc_now()
        }
        
        # Send to both sender and recipient
        deliver_to_users([from_user, to_user], timestamped_message)
        
        # Broadcast to other nodes
        broadcast_to_nodes({:route_message, timestamped_message, [from_user, to_user]})
        
        Logger.debug("Routed direct message from #{from_user} to #{to_user}")
    end
    
    {:noreply, state}
  end

  def handle_cast({:system_message, channel, message}, state) do
    # Get all users in the channel
    users = Ahoy.Core.Registry.get_channel_users(channel)
    
    # Create system message
    system_message = %{
      type: :system_message,
      channel: channel,
      message: message,
      timestamp: DateTime.utc_now()
    }
    
    # Send to all users in channel
    deliver_to_users(users, system_message)
    
    # Broadcast to other nodes
    broadcast_to_nodes({:route_message, system_message, users})
    
    Logger.debug("Routed system message to #{channel}: #{message}")
    
    {:noreply, state}
  end

  # Handle messages from other nodes
  @impl true
  def handle_info({:route_message, message, target_users}, state) do
    # Deliver message received from another node
    deliver_to_users(target_users, message)
    {:noreply, state}
  end

  def handle_info({:user_joined, username, channel}, state) do
    # System message when user joins channel
    send_system_message(channel, "#{username} joined #{channel}")
    {:noreply, state}
  end

  def handle_info({:user_left, username, channel}, state) do
    # System message when user leaves channel
    send_system_message(channel, "#{username} left #{channel}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Router received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helper functions
  defp deliver_to_users(usernames, message) do
    users = Ahoy.Core.Registry.get_users()
    
    usernames
    |> Enum.each(fn username ->
      case Map.get(users, username) do
        nil -> 
          Logger.warn("Cannot deliver to unknown user: #{username}")
        
        user_info ->
          deliver_to_user_on_node(username, user_info.node, message)
      end
    end)
  end

  defp deliver_to_user(username, message) do
    users = Ahoy.Core.Registry.get_users()
    
    case Map.get(users, username) do
      nil -> 
        Logger.warn("Cannot deliver to unknown user: #{username}")
      
      user_info ->
        deliver_to_user_on_node(username, user_info.node, message)
    end
  end

  defp deliver_to_user_on_node(username, node, message) do
    if node == Node.self() do
      # Local delivery - send to client process
      case Registry.lookup(Ahoy.ClientRegistry, username) do
        [{client_pid, _}] ->
          send(client_pid, {:message, message})
        
        [] ->
          Logger.warn("Local user #{username} has no active client process")
      end
    else
      # Remote delivery - send to user's client on their node
      send({Ahoy.Core.Router, node}, {:deliver_to_local_user, username, message})
    end
  end

  # Handle remote delivery requests
  def handle_info({:deliver_to_local_user, username, message}, state) do
    case Registry.lookup(Ahoy.ClientRegistry, username) do
      [{client_pid, _}] ->
        send(client_pid, {:message, message})
      
      [] ->
        Logger.warn("Cannot find local client for user: #{username}")
    end
    
    {:noreply, state}
  end

  defp broadcast_to_nodes(message) do
    Node.list()
    |> Enum.each(fn node ->
      send({__MODULE__, node}, message)
    end)
  end
end