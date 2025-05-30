defmodule Sequin.ProcessMetrics do
  @moduledoc """
  A module for tracking and logging process metrics, including function invocations,
  runtime, and process stats.

  This module provides:
  - Automatic interval-based logging of process stats (memory, message queue length)
  - A decorator for tracking function invocations and runtime
  - Calculation of "unaccounted time" in the process
  - Percentage breakdown of time spent in each tracked function
  - Throughput tracking (count per second)
  - Gauge value tracking

  ## Usage

  1. Add ProcessMetrics to your GenServer:

  ```elixir
  defmodule MyServer do
    use GenServer
    use Sequin.ProcessMetrics,
      interval: :timer.seconds(30),
      metric_prefix: "my_app.my_server",
      tags: %{component: "my_component"}
  end
  ```

  2. Use the decorator to track function metrics:

  ```elixir
  use Sequin.ProcessMetrics.Decorator

  @decorate track_metrics("process_message")
  def process_message(message) do
    # Your code here
  end
  ```

  3. Track throughput:

  ```elixir
  # Track messages processed
  Sequin.ProcessMetrics.increment_throughput("messages_processed")

  # Track messages processed with a specific count
  Sequin.ProcessMetrics.increment_throughput("messages_processed", 5)
  ```

  4. Track gauge values:

  ```elixir
  # Set a gauge value
  Sequin.ProcessMetrics.gauge("queue_size", queue_length)
  ```

  5. Optionally add dynamic metadata tags:

  ```elixir
  # Add user-specific tags
  Sequin.ProcessMetrics.metadata(%{user_id: "123"})
  ```

  ## How It Works

  - The module automatically schedules a periodic `:process_logging` message
  - When received, it collects metrics from the process dictionary and logs them
  - The decorator tracks function invocations and runtime in the process dictionary
  - StatsD metrics are sent with the configured prefix and tags
  """
  alias Sequin.Statsd

  require Logger

  @metrics_key :__process_metrics__
  @metrics_last_logged_at_key :__process_metrics_last_logged_at__

  # Default empty metrics structure
  @default_state %{
    # Stores function timing metrics
    timing: %{},
    # Stores throughput counters
    throughput: %{},
    # Stores gauge values
    gauge: %{},
    # Stores tags/metadata
    metadata: %{}
  }

  @doc """
  A macro that adds the ProcessMetrics behavior to a module.

  ## Options

  * `:interval` - The interval in milliseconds between logging process metrics (default: 30 seconds)
  * `:metric_prefix` - The prefix to use for StatsD metrics (default: derived from module name)
  * `:tags` - Additional tags to include in StatsD metrics (default: %{})
  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @opts opts

      defp process_metrics_interval do
        Keyword.get(@opts, :interval, :timer.seconds(30))
      end

      defp process_metrics_logger_prefix do
        Keyword.get_lazy(@opts, :logger_prefix, &default_logger_prefix/0)
      end

      defp process_metrics_metric_prefix do
        Keyword.get_lazy(@opts, :metric_prefix, &default_metric_prefix/0)
      end

      defp default_logger_prefix do
        name = __MODULE__ |> Module.split() |> List.last()
        "[#{name}]"
      end

      defp default_metric_prefix do
        __MODULE__ |> to_string() |> String.downcase() |> String.replace(".", "_")
      end

      defp process_metrics_tags do
        Keyword.get(@opts, :tags, %{})
      end

      def handle_info(:start, state) do
        Process.send_after(self(), :process_logging, process_metrics_interval())
        Sequin.ProcessMetrics.no_reply(state)
      end

      # Add the handle_info callback for process_logging
      def handle_info(:process_logging, state) do
        # Get dynamic tags from process dictionary
        dynamic_tags = Sequin.ProcessMetrics.get_metadata()
        # Merge static and dynamic tags
        tags = Map.merge(process_metrics_tags(), dynamic_tags)

        Sequin.ProcessMetrics.handle_process_logging(
          interval: process_metrics_interval(),
          metric_prefix: process_metrics_metric_prefix(),
          logger_prefix: process_metrics_logger_prefix(),
          tags: tags
        )

        Sequin.ProcessMetrics.no_reply(state)
      end
    end
  end

  # Adds compatibility with GenStage processes
  # GenStage processes use a special noreply format
  def no_reply(state) do
    {:dictionary, dictionary} = Process.info(self(), :dictionary)

    case Keyword.fetch!(dictionary, :"$initial_call") do
      {GenStage, :init, 1} ->
        {:noreply, [], state}

      _ ->
        {:noreply, state}
    end
  end

  def start do
    Process.send_after(self(), :start, 0)
  end

  # Helper functions to get and update metrics
  defp get_metrics do
    Process.get(@metrics_key, @default_state)
  end

  defp put_metrics(metrics) do
    Process.put(@metrics_key, metrics)
  end

  # Generic update function for the entire metrics map
  defp update_metrics(key, fun) when is_atom(key) and is_function(fun, 1) do
    metrics = get_metrics()
    updated_metrics = Map.update!(metrics, key, fun)
    put_metrics(updated_metrics)
    updated_metrics
  end

  # Update a specific metric within a category
  defp update_metric(category, name, default, fun) when is_atom(category) and is_binary(name) and is_function(fun, 1) do
    update_metrics(category, fn category_map ->
      Map.update(category_map, name, default, fun)
    end)
  end

  @doc """
  Sets metadata tags for metrics in the process dictionary.

  ## Parameters

  * `tags` - A map of tags to include in StatsD metrics
  """
  def metadata(tags) when is_map(tags) do
    update_metrics(:metadata, &Map.merge(&1, tags))
  end

  @doc """
  Gets the current metadata tags from the process dictionary.

  ## Returns

  A map of tags
  """
  def get_metadata do
    get_metrics().metadata
  end

  @doc """
  Increments a throughput counter.

  This function tracks counts that will be converted to per-second rates
  when metrics are logged.

  ## Parameters

  * `name` - The name of the throughput metric
  * `count` - The amount to increment the counter by (default: 1)
  """
  def increment_throughput(name, count \\ 1) do
    update_metric(:throughput, name, count, &(&1 + count))
  end

  @doc """
  Sets a gauge value.

  This function stores the current value of a metric that represents
  a point-in-time measurement (like queue size, connection count, etc.)

  ## Parameters

  * `name` - The name of the gauge metric
  * `value` - The current value of the gauge
  """
  def gauge(name, value) do
    update_metric(:gauge, name, value, fn _ -> value end)
  end

  @doc """
  Updates timing metrics for a function.
  Used internally by the decorator.

  ## Parameters

  * `name` - The name of the function
  * `time_ms` - The time in milliseconds
  """
  def update_timing(name, time_ms) do
    update_metric(:timing, name, %{count: 1, total_ms: time_ms}, fn metrics ->
      %{
        count: metrics.count + 1,
        total_ms: metrics.total_ms + time_ms
      }
    end)
  end

  @doc """
  Handles the process_logging message.

  This function:
  1. Collects process stats (memory, message queue length)
  2. Collects timing metrics from the process dictionary
  3. Calculates unaccounted time
  4. Logs all metrics
  5. Clears timing metrics
  6. Schedules the next process_logging message

  ## Parameters

  * `interval` - The interval in milliseconds between logging process metrics
  * `metric_prefix` - The prefix to use for StatsD metrics
  * `tags` - Additional tags to include in StatsD metrics
  """
  def handle_process_logging(interval: interval, metric_prefix: metric_prefix, logger_prefix: logger_prefix, tags: tags) do
    now = System.monotonic_time(:millisecond)
    last_logged_at = Process.get(@metrics_last_logged_at_key)
    interval_ms = if last_logged_at, do: now - last_logged_at

    info =
      Process.info(self(), [
        # Total memory used by process in bytes
        :memory,
        # Number of messages in queue
        :message_queue_len
      ])

    metadata = [
      memory_mb: Float.round(info[:memory] / 1_024 / 1_024, 2),
      message_queue_len: info[:message_queue_len]
    ]

    # Get all metrics from the process dictionary
    metrics = get_metrics()

    # Extract timing metrics
    timing_metrics = metrics.timing

    # Convert timing metrics to format needed for logging and StatsD
    runtime_metrics =
      Enum.map(timing_metrics, fn {name, data} ->
        {name, data.total_ms, data.count}
      end)

    # Log all timing metrics as histograms with operation tag
    Enum.each(runtime_metrics, fn {name, total_ms, _count} ->
      Statsd.histogram("#{metric_prefix}.operation_time_ms", total_ms, tags: Map.put(tags, :operation, name))
    end)

    # Process throughput metrics
    throughput_metrics = metrics.throughput

    # Format throughput metrics for logging with per-second rates
    if_result =
      if interval_ms && interval_ms > 0 do
        Enum.map(throughput_metrics, fn {name, count} ->
          rate = count / (interval_ms / 1000)
          {:"#{name}_throughput", "#{Float.round(rate, 2)}/s"}
        end)
      else
        Enum.map(throughput_metrics, fn {name, count} ->
          {:"#{name}_count", count}
        end)
      end

    formatted_throughput =
      Keyword.new(if_result)

    # Log throughput metrics to StatsD
    if interval_ms && interval_ms > 0 do
      Enum.each(throughput_metrics, fn {name, count} ->
        rate = count / (interval_ms / 1000)
        Statsd.gauge("#{metric_prefix}.#{name}_per_sec", rate, tags: tags)
      end)
    end

    # Process gauge metrics
    gauge_metrics = metrics.gauge

    # Format gauge metrics for logging
    formatted_gauges =
      Keyword.new(gauge_metrics, fn {name, value} -> {:"#{name}", value} end)

    # Log gauge metrics to StatsD
    Enum.each(gauge_metrics, fn {name, value} ->
      Statsd.gauge("#{metric_prefix}.#{name}", value, tags: tags)
    end)

    # Calculate unaccounted time
    total_accounted_ms =
      Enum.reduce(runtime_metrics, 0, fn {_name, total_ms, _count}, acc ->
        acc + total_ms
      end)

    unaccounted_ms =
      if interval_ms do
        max(0, interval_ms - total_accounted_ms)
      end

    if unaccounted_ms do
      # Log unaccounted time with same metric but different operation tag
      Sequin.Statsd.histogram("#{metric_prefix}.operation_time_ms", unaccounted_ms,
        tags: Map.put(tags, :operation, "unaccounted")
      )
    end

    # Calculate percentages for each operation
    percentages =
      if interval_ms && interval_ms > 0 do
        Keyword.new(runtime_metrics, fn {name, total_ms, _count} ->
          {:"#{name}_percent", Float.round(total_ms / interval_ms * 100, 2)}
        end)
      else
        []
      end

    # Add unaccounted percentage
    percentages =
      if interval_ms && interval_ms > 0 && unaccounted_ms do
        Keyword.put(percentages, :unaccounted_percent, Float.round(unaccounted_ms / interval_ms * 100, 2))
      else
        percentages
      end

    # Format timing metrics for logging
    formatted_timing =
      timing_metrics
      |> Enum.flat_map(fn {name, data} ->
        [
          {:"#{name}_count", data.count},
          {:"#{name}_total_ms", data.total_ms}
        ]
      end)
      |> Keyword.new()

    metadata =
      metadata
      |> Keyword.merge(formatted_timing)
      |> Keyword.merge(percentages)
      |> Keyword.merge(formatted_throughput)
      |> Keyword.merge(formatted_gauges)
      |> Sequin.Keyword.put_if_present(:unaccounted_total_ms, unaccounted_ms)
      |> Keyword.put(:interval_ms, interval_ms)

    # Add tags to metadata for logging
    metadata =
      if map_size(tags) > 0 do
        Keyword.put(metadata, :tags, tags)
      else
        metadata
      end

    Logger.info("#{logger_prefix} Process metrics", metadata)

    # Clear metrics after logging
    put_metrics(@default_state)

    # Schedule next logging and update last logged time
    schedule_process_logging(interval)
    Process.put(@metrics_last_logged_at_key, now)
  end

  # Private functions

  defp schedule_process_logging(interval) do
    # If this is the first time we're scheduling, set the interval to 0
    # to log immediately after startup
    actual_interval =
      if Process.get(@metrics_last_logged_at_key) == nil do
        0
      else
        interval
      end

    Process.send_after(self(), :process_logging, actual_interval)
  end
end

defmodule Sequin.ProcessMetrics.Decorator do
  @moduledoc """
  Provides decorators for tracking function invocations and runtime.

  ## Usage

  ```elixir
  use Sequin.ProcessMetrics.Decorator

  @decorate track_metrics("process_message")
  def process_message(message) do
    # Your code here
  end
  ```
  """

  use Decorator.Define, track_metrics: 1

  @doc """
  A decorator that tracks function invocations and runtime.

  ## Parameters

  * `name` - The name of the function to track
  """
  def track_metrics(name, body, _context) do
    quote do
      # Execute the function and time it
      {time, result} = :timer.tc(fn -> unquote(body) end)

      # Convert microseconds to milliseconds and update metrics
      time_ms = div(time, 1000)
      Sequin.ProcessMetrics.update_timing(unquote(name), time_ms)

      result
    end
  end
end
