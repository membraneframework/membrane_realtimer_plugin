defmodule Membrane.Realtimer do
  @moduledoc """
  Sends buffers to the output in real time, according to buffers' timestamps.

  If buffers come in slower than realtime, they're sent as they come in.

  It can be reset by sending `%#{inspect(__MODULE__)}.Events.Reset{}` event on its input pad.
  """
  use Membrane.Filter

  alias __MODULE__.Events
  alias Membrane.{Buffer, Time}

  def_input_pad :input,
    accepted_format: _any,
    flow_control: :manual,
    demand_unit: :buffers

  def_output_pad :output,
    accepted_format: _any,
    flow_control: :push

  def_options max_latency: [
                spec: Time.non_neg(),
                default: 0,
                inspector: &Time.inspect/1,
                description: """
                This element will keep a part of the stream of duration specified by this option
                buffered. The purpose of this it to handle cases where the incoming stream can get
                lagged, for example when an element up the pipeline can get held up for some time
                and then produce all the "late" media at once. The buffered stream gives Realtimer some
                margin in waiting for this "late" media, so that the outgoing stream is still smooth.
                The initial accumulation of the buffer can introduce some latency, especially when
                the input stream is in realtime, but it will never exceed the amount provided via this
                option.
                """
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            max_latency: Time.non_neg(),
            current_substream_id: non_neg_integer(),
            offset: Time.non_neg() | :calculating,
            newest_timestamp: Time.non_neg(),
            reference_timestamps: %{
              absolute: Time.non_neg() | :to_be_initialized,
              stream: Time.non_neg() | :to_be_initialized
            },
            substreams: %{
              non_neg_integer() =>
                %{
                  finished: boolean(),
                  action_batches_queue: [
                    %{timestamp: Time.non_neg(), actions: [Membrane.Element.Action.t()]}
                  ]
                }
                | :to_be_initialized
            }
          }

    @enforce_keys [:max_latency]

    defstruct @enforce_keys ++
                [
                  current_substream_id: 0,
                  reference_timestamps: %{
                    absolute: :to_be_initialized,
                    stream: :to_be_initialized
                  },
                  substreams: %{0 => :to_be_initialized},
                  offset: :calculating,
                  newest_timestamp: 0
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %State{max_latency: opts.max_latency}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: :input], state}
  end

  @impl true
  def handle_start_of_stream(:input, _ctx, %State{} = state) do
    Process.send_after(
      self(),
      :initial_latency_passed,
      Time.as_milliseconds(state.max_latency, :round)
    )

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    buffer_timestamp = Buffer.get_dts_or_pts(buffer)
    monotonic_time = Time.monotonic_time()

    state = initialize_uninitialized_reference_timestamps(buffer_timestamp, monotonic_time, state)

    substream =
      case state.substreams[state.current_substream_id] do
        :to_be_initialized ->
          %{
            finished: false,
            action_batches_queue: [
              %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}
            ]
          }

        initialized_substream ->
          %{
            initialized_substream
            | action_batches_queue: [
                %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}
                | initialized_substream.action_batches_queue
              ]
          }
      end

    %State{} = state = put_in(state.substreams[state.current_substream_id], substream)
    substream_duration = calculate_substream_duration(substream.action_batches_queue)

    demand_action =
      if substream_duration < state.max_latency do
        [demand: :input]
      else
        []
      end

    if state.offset != :calculating do
      schedule_next_buffer(
        buffer_timestamp,
        state.offset,
        state.reference_timestamps,
        state.current_substream_id
      )
    end

    state =
      if substream_duration >= state.max_latency do
        accumulation_time = monotonic_time - state.reference_timestamps.absolute
        lock_offset_if_still_calculating(accumulation_time, state)
      else
        state
      end

    state = %State{state | newest_timestamp: buffer_timestamp}

    {demand_action, state}
  end

  defp initialize_uninitialized_reference_timestamps(
         buffer_timestamp,
         monotonic_time,
         %State{} = state
       ) do
    absolute_timestamp =
      if state.reference_timestamps.absolute == :to_be_initialized,
        do: monotonic_time,
        else: state.reference_timestamps.absolute

    stream_timestamp =
      if state.reference_timestamps.stream == :to_be_initialized,
        do: buffer_timestamp,
        else: state.reference_timestamps.stream

    %State{
      state
      | reference_timestamps: %{absolute: absolute_timestamp, stream: stream_timestamp}
    }
  end

  defp calculate_substream_duration(action_batches_queue) do
    if length(action_batches_queue) < 2 do
      0
    else
      List.first(action_batches_queue).timestamp - List.last(action_batches_queue).timestamp
    end
  end

  defp schedule_next_buffer(buffer_timestamp, offset, reference_timestamps, current_substream_id) do
    buffer_relative_timestamp =
      buffer_timestamp - reference_timestamps.stream

    target_time =
      reference_timestamps.absolute + buffer_relative_timestamp + offset

    interval =
      (target_time - Time.monotonic_time())
      |> max(0)
      |> Time.as_milliseconds(:round)

    Process.send_after(self(), {:send_next_action_batch, current_substream_id}, interval)
  end

  defp lock_offset_if_still_calculating(offset, %State{} = state) do
    if state.offset == :calculating do
      state = %State{state | offset: offset}

      Enum.each(
        state.substreams[0].action_batches_queue,
        &schedule_next_buffer(&1.timestamp, offset, state.reference_timestamps, 0)
      )

      state
    else
      state
    end
  end

  @impl true
  def handle_info(:initial_latency_passed, _ctx, %State{} = state) do
    state = lock_offset_if_still_calculating(state.max_latency, state)

    {[], state}
  end

  @impl true
  def handle_info({:send_next_action_batch, substream_id}, ctx, %State{} = state) do
    substream = state.substreams[substream_id]

    {oldest_action_batch, rest_of_action_batches} =
      List.pop_at(substream.action_batches_queue, -1)

    actions = Enum.reverse(oldest_action_batch.actions)

    substream = %{substream | action_batches_queue: rest_of_action_batches}

    substream_duration = calculate_substream_duration(substream.action_batches_queue)

    demand_action =
      if ctx.pads.input.end_of_stream? or ctx.pads.input.manual_demand_size > 0 or
           substream_duration > state.max_latency or substream.finished do
        []
      else
        [demand: :input]
      end

    state = put_in(state.substreams[substream_id], substream)

    {actions ++ demand_action, state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, ctx, %State{} = state) do
    accumulation_time = Time.monotonic_time() - state.reference_timestamps.absolute
    state = lock_offset_if_still_calculating(accumulation_time, state)

    state = update_in(state.substreams[state.current_substream_id], &%{&1 | finished: true})

    state = update_in(state.current_substream_id, &(&1 + 1))

    state =
      update_in(state.substreams, &Map.put(&1, state.current_substream_id, :to_be_initialized))

    previous_substream_length =
      state.newest_timestamp - state.reference_timestamps.stream

    reference_timestamps = %{
      absolute: state.reference_timestamps.absolute + previous_substream_length,
      stream: :to_be_initialized
    }

    state = put_in(state.reference_timestamps, reference_timestamps)

    if ctx.pads.input.manual_demand_size == 0 do
      {[demand: :input], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, %State{} = state) do
    maybe_queue_action({:event, {:output, event}}, state)
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    maybe_queue_action({:stream_format, {:output, stream_format}}, state)
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    maybe_queue_action({:end_of_stream, :output}, state)
  end

  @spec maybe_queue_action(Membrane.Element.Action.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp maybe_queue_action(action, state) do
    if state.substreams[state.current_substream_id] == :to_be_initialized or
         state.substreams[state.current_substream_id].action_batches_queue == [] do
      {[action], state}
    else
      state =
        update_in(state.substreams[state.current_substream_id].action_batches_queue, fn
          action_batches_queue ->
            List.update_at(action_batches_queue, 0, &%{&1 | actions: [action | &1.actions]})
        end)

      {[], state}
    end
  end
end
