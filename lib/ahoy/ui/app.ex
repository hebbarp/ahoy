defmodule Ahoy.UI.App do
  @moduledoc """
  Simple command-line UI for Ahoy chat.
  Replaces Ratatouille with basic STDIN/STDOUT interaction.
  """
  
  require Logger

  def start(username, client_pid, _opts \\ []) do
    # Store username in process dictionary for display_message
    Process.put(:username, username)
    
    IO.puts("\n=== Ahoy Chat - #{username} ===")
    IO.puts("Type /help for commands, /quit to exit")
    IO.puts("Connecting to network...\n")
    
    # Start input loop
    input_loop(username, client_pid)
  end

  defp input_loop(username, client_pid) do
    # Start input task
    input_task = Task.async(fn -> 
      input_loop_main(username, client_pid)
    end)
    
    # Message receiving loop
    message_loop(input_task)
  end

  defp input_loop_main(username, client_pid) do
    case IO.gets("#{username}> ") do
      :eof ->
        send(self(), :quit)
        
      {:error, reason} ->
        IO.puts("Input error: #{inspect(reason)}")
        input_loop_main(username, client_pid)
        
      input when is_binary(input) ->
        trimmed = String.trim(input)
        
        case handle_input(trimmed, username, client_pid) do
          :quit -> 
            send(self(), :quit)
          
          :continue -> 
            input_loop_main(username, client_pid)
        end
    end
  end

  # Main message receiving loop
  defp message_loop(input_task) do
    receive do
      {:ui_message, message} ->
        display_message(message)
        message_loop(input_task)
      
      :quit ->
        Task.shutdown(input_task)
        IO.puts("Goodbye!")
        System.halt(0)
      
      other ->
        IO.puts("Unknown UI message: #{inspect(other)}")
        message_loop(input_task)
    end
  end

  defp display_message(message) do
    case message do
      %{type: :channel_message, from: from, channel: channel, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("\r[#{time}] #{channel} <#{from}> #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :direct_message, from: from, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("\r[#{time}] DM from #{from}: #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :system_message, message: msg} ->
        IO.puts("\r* #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :error, message: msg} ->
        IO.puts("\rERROR: #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      _ ->
        IO.puts("\rUnknown message: #{inspect(message)}")
        IO.write("#{Process.get(:username, "user")}> ")
    end
  end

  defp handle_input("", _username, _client_pid), do: :continue
  
  defp handle_input("/quit", _username, _client_pid), do: :quit
  
  defp handle_input("/help", _username, _client_pid) do
    IO.puts("""
    
    Available commands:
    /help              - Show this help
    /join #channel     - Join a channel
    /leave #channel    - Leave a channel  
    /msg user message  - Send direct message
    /who [#channel]    - List users
    /network           - Show network info
    /quit              - Exit Ahoy
    
    Regular text will be sent to your current channel.
    """)
    :continue
  end
  
  defp handle_input("/network", _username, _client_pid) do
    info = Ahoy.network_info()
    IO.puts("""
    
    Network Information:
    Own node: #{info.own_node}
    Connected nodes: #{inspect(info.connected_nodes)}
    Total cluster size: #{info.total_cluster_size}
    """)
    :continue
  end
  
  defp handle_input("/sync", _username, _client_pid) do
    # Manual registry sync for debugging
    Node.list()
    |> Enum.each(fn node ->
      send({Ahoy.Core.Registry, node}, :request_users)
    end)
    IO.puts("Requested user sync from all connected nodes")
    :continue
  end
  
  defp handle_input("/who", _username, _client_pid) do
    users = Ahoy.list_users()
    IO.puts("\nOnline users:")
    Enum.each(users, fn {username, info} ->
      channels = Enum.join(info.channels, ", ")
      # Extract hostname from node (e.g., "dev@192.168.0.101" -> "192.168.0.101")
      node_host = case String.split(to_string(info.node), "@") do
        [_name, host] -> host
        _ -> to_string(info.node)
      end
      IO.puts("  #{username}@#{node_host} - channels: [#{channels}]")
    end)
    IO.puts("")
    :continue
  end
  
  defp handle_input("/join " <> channel, username, client_pid) do
    channel = String.trim(channel)
    if String.starts_with?(channel, "#") do
      # Send join command to client
      case Ahoy.Core.Client.join_channel(client_pid, channel) do
        :ok ->
          IO.puts("Joined #{channel}")
        {:error, :already_in_channel} ->
          IO.puts("Already in #{channel}")
        {:error, reason} ->
          IO.puts("Failed to join #{channel}: #{inspect(reason)}")
      end
    else
      IO.puts("Channel names must start with #")
    end
    :continue
  end
  
  defp handle_input("/leave " <> channel, username, client_pid) do
    channel = String.trim(channel)
    # TODO: Send leave command to client
    IO.puts("Leaving #{channel}...")
    :continue
  end
  
  defp handle_input("/connect " <> node_name, _username, _client_pid) do
    node_name = String.trim(node_name)
    Ahoy.Core.Discovery.connect_to_node(String.to_atom(node_name))
    IO.puts("Connection attempt to #{node_name}")
    :continue
  end
  
  defp handle_input("/msg " <> rest, username, client_pid) do
    case String.split(rest, " ", parts: 2) do
      [to_user, message] ->
        Ahoy.Core.Client.send_direct_message(client_pid, to_user, message)
        IO.puts("Sent DM to #{to_user}")
      
      _ ->
        IO.puts("Usage: /msg username message")
    end
    :continue
  end
  
  defp handle_input(message, username, client_pid) do
    # Regular message to current channel
    case Ahoy.Core.Client.send_message(client_pid, message) do
      :ok ->
        # Message sent successfully (no need to print, it will come back via Router)
        :continue
      
      {:error, reason} ->
        IO.puts("Failed to send message: #{inspect(reason)}")
        :continue
    end
  end

  # Handle incoming messages from Client process
  def handle_message(message) do
    case message do
      %{type: :channel_message, from: from, channel: channel, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("[#{time}] #{channel} <#{from}> #{msg}")
      
      %{type: :direct_message, from: from, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("[#{time}] DM from #{from}: #{msg}")
      
      %{type: :system_message, message: msg} ->
        IO.puts("* #{msg}")
      
      %{type: :error, message: msg} ->
        IO.puts("ERROR: #{msg}")
      
      _ ->
        IO.puts("Unknown message: #{inspect(message)}")
    end
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 5)  # HH:MM
  end
end