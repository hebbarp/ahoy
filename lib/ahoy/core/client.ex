defmodule Ahoy.Core.Client do
  use GenServer
  require Logger

  defstruct [
    :username,
    :ui_pid,
    current_channel: nil,
    channels: [],
    message_history: []
  ]

  # Client API
  def start_link(username, ui_pid) do
    GenServer.start_link(__MODULE__, {username, ui_pid})
  end

  def join_channel(client_pid, channel) do
    GenServer.call(client_pid, {:join_channel, channel})
  end

  def leave_channel(client_pid, channel) do
    GenServer.call(client_pid, {:leave_channel, channel})
  end

  def send_message(client_pid, message) do
    GenServer.cast(client_pid, {:send_message, message})
  end

  def send_direct_message(client_pid, to_user, message) do
    GenServer.cast(client_pid, {:direct_message, to_user, message})
  end

  def switch_channel(client_pid, channel) do
    GenServer.call(client_pid, {:switch_channel, channel})
  end

  def get_state(client_pid) do
    GenServer.call(client_pid, :get_state)
  end

  def disconnect(client_pid) do
    GenServer.cast(client_pid, :disconnect)
  end

  # Server callbacks
  @impl true
  def init({username, parent_pid}) do
    # Register this client in the local registry
    {:ok, _} = Registry.register(Ahoy.ClientRegistry, username, self())
    
    # Register user globally across all nodes
    :ok = Ahoy.Core.Registry.register_user(username)
    
    state = %__MODULE__{
      username: username,
      ui_pid: nil,  # Will be set when UI sends {:ui_pid, pid}
      current_channel: nil,
      channels: [],
      message_history: []
    }
    
    Logger.info("Client started for user: #{username}")
    
    {:ok, state}
  end

  @impl true
  def handle_call({:join_channel, channel}, _from, state) do
    if channel in state.channels do
      {:reply, {:error, :already_in_channel}, state}
    else
      case Ahoy.Core.Registry.join_channel(state.username, channel) do
        :ok ->
          new_channels = [channel | state.channels]
          new_state = %{state | 
            channels: new_channels,
            current_channel: channel
          }
          
          # Notify Router about user joining
          send(Ahoy.Core.Router, {:user_joined, state.username, channel})
          
          # Send confirmation to UI
          send_to_ui(state.ui_pid, %{
            type: :system_message,
            message: "Joined #{channel}",
            timestamp: DateTime.utc_now()
          })
          
          Logger.info("#{state.username} joined #{channel}")
          {:reply, :ok, new_state}
          
        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:leave_channel, channel}, _from, state) do
    if channel not in state.channels do
      {:reply, {:error, :not_in_channel}, state}
    else
      case Ahoy.Core.Registry.leave_channel(state.username, channel) do
        :ok ->
          new_channels = List.delete(state.channels, channel)
          new_current = if state.current_channel == channel do
            List.first(new_channels)
          else
            state.current_channel
          end
          
          new_state = %{state | 
            channels: new_channels,
            current_channel: new_current
          }
          
          # Notify Router about user leaving
          send(Ahoy.Core.Router, {:user_left, state.username, channel})
          
          # Send confirmation to UI
          send_to_ui(state.ui_pid, %{
            type: :system_message,
            message: "Left #{channel}",
            timestamp: DateTime.utc_now()
          })
          
          Logger.info("#{state.username} left #{channel}")
          {:reply, :ok, new_state}
          
        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:switch_channel, channel}, _from, state) do
    if channel in state.channels do
      new_state = %{state | current_channel: channel}
      
      # Send confirmation to UI
      send_to_ui(state.ui_pid, %{
        type: :system_message,
        message: "Switched to #{channel}",
        timestamp: DateTime.utc_now()
      })
      
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_in_channel}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    case state.current_channel do
      nil ->
        # Send error to UI
        send_to_ui(state.ui_pid, %{
          type: :error,
          message: "Not in any channel. Use /join #channelname first.",
          timestamp: DateTime.utc_now()
        })
        
      channel ->
        # Send message through Router
        Ahoy.Core.Router.send_channel_message(state.username, channel, message)
    end
    
    {:noreply, state}
  end

  def handle_cast({:direct_message, to_user, message}, state) do
    # Send direct message through Router
    Ahoy.Core.Router.send_direct_message(state.username, to_user, message)
    {:noreply, state}
  end

  def handle_cast(:disconnect, state) do
    Logger.info("#{state.username} disconnecting")
    {:stop, :normal, state}
  end

  # Handle UI PID from main process
  @impl true
  def handle_info({:ui_pid, ui_pid}, state) do
    # Monitor the UI process
    Process.monitor(ui_pid)
    
    # Update state with UI PID
    new_state = %{state | ui_pid: ui_pid}
    
    # Send welcome message to UI
    send_to_ui(ui_pid, %{
      type: :system_message,
      message: "Welcome to Ahoy, #{state.username}! Type /help for commands.",
      timestamp: DateTime.utc_now()
    })
    
    {:noreply, new_state}
  end

  # Handle incoming messages from Router
  def handle_info({:message, message}, state) do
    # Add to message history
    new_history = [message | state.message_history] |> Enum.take(100)
    new_state = %{state | message_history: new_history}
    
    # Forward to UI if UI PID is set
    if state.ui_pid do
      send_to_ui(state.ui_pid, message)
    end
    
    {:noreply, new_state}
  end

  # Handle UI process termination
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    if pid == state.ui_pid do
      Logger.info("UI process for #{state.username} terminated: #{inspect(reason)}")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Client #{state.username} received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Client for #{state.username} terminating: #{inspect(reason)}")
    
    # Leave all channels
    Enum.each(state.channels, fn channel ->
      Ahoy.Core.Registry.leave_channel(state.username, channel)
      send(Ahoy.Core.Router, {:user_left, state.username, channel})
    end)
    
    # Unregister user globally
    Ahoy.Core.Registry.unregister_user(state.username)
    
    :ok
  end

  # Private helper functions
  defp send_to_ui(ui_pid, message) do
    send(ui_pid, {:ui_message, message})
  end
end