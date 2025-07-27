defmodule Ahoy.Core.Discovery do
  use GenServer
  require Logger

  @broadcast_port 4567
  @discovery_interval 30_000  # 30 seconds
  @broadcast_address {255, 255, 255, 255}

  defstruct [
    :udp_socket,
    :timer_ref,
    discovered_nodes: MapSet.new(),
    own_info: %{}
  ]

  # Client API
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_discovered_nodes() do
    GenServer.call(__MODULE__, :get_discovered_nodes)
  end

  def force_discovery() do
    GenServer.cast(__MODULE__, :force_discovery)
  end

  def connect_to_node(node_name) do
    GenServer.cast(__MODULE__, {:connect_to_node, node_name})
  end

  # Server callbacks
  @impl true
  def init(_args) do
    # Get our own node information
    own_node = Node.self()
    own_info = %{
      node: own_node,
      timestamp: System.system_time(:second),
      version: "1.0.0"
    }

    # Open UDP socket for broadcasting and receiving
    case :gen_udp.open(@broadcast_port, [
      :binary,
      {:broadcast, true},
      {:active, true},
      {:reuseaddr, true}
    ]) do
      {:ok, socket} ->
        state = %__MODULE__{
          udp_socket: socket,
          own_info: own_info,
          discovered_nodes: MapSet.new()
        }

        # Start periodic discovery broadcasts
        timer_ref = Process.send_after(self(), :broadcast_discovery, 1000)
        new_state = %{state | timer_ref: timer_ref}

        Logger.info("Discovery started on #{own_node}, broadcasting on port #{@broadcast_port}")
        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_discovered_nodes, _from, state) do
    nodes = state.discovered_nodes |> MapSet.to_list()
    {:reply, nodes, state}
  end

  @impl true
  def handle_cast(:force_discovery, state) do
    broadcast_discovery(state)
    {:noreply, state}
  end

  def handle_cast({:connect_to_node, node_name}, state) do
    case Node.connect(node_name) do
      true ->
        Logger.info("Successfully connected to node: #{node_name}")
      
      false ->
        Logger.warn("Failed to connect to node: #{node_name}")
    end
    
    {:noreply, state}
  end

  @impl true
  def handle_info(:broadcast_discovery, state) do
    # Send discovery broadcast
    broadcast_discovery(state)
    
    # Schedule next broadcast
    timer_ref = Process.send_after(self(), :broadcast_discovery, @discovery_interval)
    new_state = %{state | timer_ref: timer_ref}
    
    {:noreply, new_state}
  end

  # Handle incoming UDP discovery messages
  def handle_info({:udp, socket, ip, port, data}, %{udp_socket: socket} = state) do
    case decode_discovery_message(data) do
      {:ok, remote_info} ->
        handle_discovery_message(remote_info, ip, state)
      
      {:error, reason} ->
        Logger.debug("Invalid discovery message from #{inspect(ip)}: #{reason}")
        {:noreply, state}
    end
  end

  def handle_info({:udp_closed, socket}, %{udp_socket: socket} = state) do
    Logger.warn("UDP socket closed unexpectedly")
    {:stop, :udp_closed, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Discovery received unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Discovery terminating: #{inspect(reason)}")
    
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    if state.udp_socket do
      :gen_udp.close(state.udp_socket)
    end
    
    :ok
  end

  # Private functions
  defp broadcast_discovery(state) do
    message = encode_discovery_message(state.own_info)
    
    case :gen_udp.send(state.udp_socket, @broadcast_address, @broadcast_port, message) do
      :ok ->
        Logger.debug("Sent discovery broadcast")
      
      {:error, reason} ->
        Logger.warn("Failed to send discovery broadcast: #{inspect(reason)}")
    end
  end

  defp handle_discovery_message(remote_info, ip, state) do
    remote_node = remote_info.node
    
    # Don't process our own broadcasts
    if remote_node == Node.self() do
      {:noreply, state}
    else
      # Add to discovered nodes
      new_discovered = MapSet.put(state.discovered_nodes, remote_info)
      new_state = %{state | discovered_nodes: new_discovered}
      
      # Attempt to connect if not already connected
      if remote_node not in Node.list() do
        Logger.info("Discovered new Ahoy node: #{remote_node} at #{inspect(ip)}")
        
        case Node.connect(remote_node) do
          true ->
            Logger.info("Successfully connected to #{remote_node}")
            
            # Send welcome message to Router for system notifications
            send(Ahoy.Core.Router, {:node_connected, remote_node})
            
          false ->
            Logger.warn("Failed to connect to discovered node: #{remote_node}")
        end
      end
      
      {:noreply, new_state}
    end
  end

  defp encode_discovery_message(info) do
    # Simple JSON-like encoding for discovery messages
    data = %{
      type: "ahoy_discovery",
      node: Atom.to_string(info.node),
      timestamp: info.timestamp,
      version: info.version
    }
    
    :erlang.term_to_binary(data)
  end

  defp decode_discovery_message(binary) do
    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        %{type: "ahoy_discovery", node: node_str, timestamp: ts, version: ver} ->
          {:ok, %{
            node: String.to_atom(node_str),
            timestamp: ts,
            version: ver
          }}
        
        _ ->
          {:error, :invalid_format}
      end
    rescue
      _ -> {:error, :decode_failed}
    end
  end

  # Public utility functions for manual node management
  def list_connected_nodes() do
    Node.list()
  end

  def disconnect_from_node(node_name) do
    case Node.disconnect(node_name) do
      true ->
        Logger.info("Disconnected from node: #{node_name}")
        :ok
      
      false ->
        Logger.warn("Failed to disconnect from node: #{node_name}")
        {:error, :disconnect_failed}
    end
  end

  def get_network_info() do
    %{
      own_node: Node.self(),
      connected_nodes: Node.list(),
      discovered_nodes: get_discovered_nodes(),
      total_cluster_size: 1 + length(Node.list())
    }
  end
end