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
                This element will keep a part of the stream, of duration specified by this option,
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

    @type action_batch :: %{timestamp: Time.non_neg(), actions: [Membrane.Element.Action.t()]}

    @type t :: %__MODULE__{
            max_latency: Time.non_neg(),
            offset: Time.non_neg() | :calculating,
            newest_timestamp: Time.non_neg(),
            reference_timestamps: %{
              absolute: Time.non_neg() | nil,
              stream: Time.non_neg() | nil
            },
            current_substream_id: non_neg_integer(),
            substreams: %{non_neg_integer() => Qex.t(action_batch())}
          }

    @enforce_keys [:max_latency]

    defstruct @enforce_keys ++
                [
                  current_substream_id: 0,
                  reference_timestamps: %{absolute: nil, stream: nil},
                  offset: :calculating,
                  newest_timestamp: 0,
                  substreams: %{0 => Qex.new()}
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
      :max_latency_passed,
      Time.as_milliseconds(state.max_latency, :round)
    )

    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    buffer_timestamp = Buffer.get_dts_or_pts(buffer)
    monotonic_time = Time.monotonic_time()

    state = initialize_reference_timestamps(buffer_timestamp, monotonic_time, state)

    new_action_batch = %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}

    %State{} =
      state =
      update_in(state.substreams[state.current_substream_id], &Qex.push(&1, new_action_batch))

    buffered_stream_duration = calculate_buffered_stream_duration(state)

    demand_action =
      if buffered_stream_duration < state.max_latency do
        [demand: :input]
      else
        []
      end

    if state.offset != :calculating do
      schedule_action_batch(buffer_timestamp, state)
    end

    state =
      if buffered_stream_duration >= state.max_latency do
        accumulation_time = monotonic_time - state.reference_timestamps.absolute
        lock_offset_if_still_calculating(accumulation_time, state)
      else
        state
      end

    state = %State{state | newest_timestamp: buffer_timestamp}

    {demand_action, state}
  end

  @impl true
  def handle_info(:max_latency_passed, _ctx, %State{} = state) do
    state = lock_offset_if_still_calculating(state.max_latency, state)

    {[], state}
  end

  @impl true
  def handle_info({:send_scheduled_action_batch, substream_id}, ctx, %State{} = state) do
    {oldest_action_batch, substream} = Qex.pop!(state.substreams[substream_id])

    actions = Enum.reverse(oldest_action_batch.actions)

    state = put_in(state.substreams[substream_id], substream)

    buffered_stream_duration = calculate_buffered_stream_duration(state)

    demand_action =
      if ctx.pads.input.end_of_stream? or ctx.pads.input.manual_demand_size > 0 or
           buffered_stream_duration > state.max_latency do
        []
      else
        [demand: :input]
      end

    {actions ++ demand_action, state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, ctx, %State{} = state) do
    state = update_in(state.current_substream_id, &(&1 + 1))

    state =
      update_in(state.substreams, &Map.put(&1, state.current_substream_id, Qex.new()))

    previous_substream_length =
      state.newest_timestamp - state.reference_timestamps.stream

    reference_timestamps = %{
      absolute: state.reference_timestamps.absolute + previous_substream_length,
      stream: nil
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

  @spec initialize_reference_timestamps(Membrane.Time.t(), Membrane.Time.non_neg(), State.t()) ::
          State.t()
  defp initialize_reference_timestamps(buffer_timestamp, monotonic_time, %State{} = state) do
    %State{
      state
      | reference_timestamps: %{
          absolute: state.reference_timestamps.absolute || monotonic_time,
          stream: state.reference_timestamps.stream || buffer_timestamp
        }
    }
  end

  @spec calculate_buffered_stream_duration(State.t()) :: Membrane.Time.t()
  defp calculate_buffered_stream_duration(state) do
    Enum.sum_by(state.substreams, fn {_substream_id, substream} ->
      case {Qex.last(substream), Qex.first(substream)} do
        {:empty, :empty} ->
          0

        {{:value, latest_action_batch}, {:value, oldest_action_batch}} ->
          latest_action_batch.timestamp - oldest_action_batch.timestamp
      end
    end)
  end

  @spec schedule_action_batch(Time.t(), State.t()) :: reference()
  defp schedule_action_batch(buffer_timestamp, state) do
    buffer_relative_timestamp =
      buffer_timestamp - state.reference_timestamps.stream

    target_time =
      state.reference_timestamps.absolute + buffer_relative_timestamp + state.offset

    send_after_time =
      (target_time - Time.monotonic_time())
      |> max(0)
      |> Time.as_milliseconds(:round)

    Process.send_after(
      self(),
      {:send_scheduled_action_batch, state.current_substream_id},
      send_after_time
    )
  end

  @spec lock_offset_if_still_calculating(Time.non_neg(), State.t()) :: State.t()
  defp lock_offset_if_still_calculating(offset, %State{} = state) do
    if state.offset == :calculating do
      state = %State{state | offset: offset}

      Enum.each(state.substreams, fn {_substream_id, substream} ->
        Enum.each(substream, &schedule_action_batch(&1.timestamp, state))
      end)

      state
    else
      state
    end
  end

  @spec maybe_queue_action(Membrane.Element.Action.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp maybe_queue_action(action, state) do
    case Qex.pop_back(state.substreams[state.current_substream_id]) do
      {:empty, _queue} ->
        {[action], state}

      {{:value, latest_action_batch}, substream} ->
        latest_action_batch = update_in(latest_action_batch.actions, &[action | &1])

        substream = Qex.push(substream, latest_action_batch)

        state =
          put_in(
            state.substreams[state.current_substream_id],
            substream
          )

        {[], state}
    end
  end
end
