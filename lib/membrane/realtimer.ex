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

    defmodule Substream do
      @moduledoc false

      @type t :: %__MODULE__{
              action_batches_queue:
                Qex.t(%{timestamp: Time.non_neg(), actions: [Membrane.Element.Action.t()]}),
              reference_timestamps: %{
                absolute: Time.t() | nil,
                stream: Time.t() | nil
              }
            }

      @enforce_keys [:reference_timestamps]

      defstruct @enforce_keys ++
                  [
                    action_batches_queue: Qex.new()
                  ]
    end

    @type t :: %__MODULE__{
            max_latency: Time.non_neg(),
            offset: Time.non_neg() | :calculating,
            newest_timestamp: Time.non_neg(),
            current_substream_id: non_neg_integer(),
            start_of_stream_time: Time.t() | nil,
            initialize_new_substream: boolean(),
            substreams: %{non_neg_integer() => Substream.t()}
          }

    @enforce_keys [:max_latency]

    defstruct @enforce_keys ++
                [
                  current_substream_id: 0,
                  substreams: %{},
                  initialize_new_substream: true,
                  offset: :calculating,
                  newest_timestamp: 0,
                  start_of_stream_time: nil
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

    {[], %State{state | start_of_stream_time: Time.monotonic_time()}}
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, %State{} = state) do
    buffer_timestamp = Buffer.get_dts_or_pts(buffer)

    state = maybe_initialize_new_substream(buffer_timestamp, state)

    new_action_batch = %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}

    state =
      update_in(
        state.substreams[state.current_substream_id].action_batches_queue,
        &Qex.push(&1, new_action_batch)
      )

    if state.offset != :calculating do
      maybe_schedule_action_batch(buffer_timestamp, state.current_substream_id, state)
    end

    buffered_stream_duration = calculate_buffered_stream_duration(state)

    demand_action = maybe_demand(buffered_stream_duration, ctx, state)

    %State{} =
      state =
      if buffered_stream_duration >= state.max_latency do
        lock_offset_if_still_calculating(state)
      else
        state
      end

    state = %State{state | newest_timestamp: buffer_timestamp}

    {demand_action, state}
  end

  @impl true
  def handle_info(:max_latency_passed, _ctx, %State{} = state) do
    state = lock_offset_if_still_calculating(state)

    {[], state}
  end

  @impl true
  def handle_info({:send_scheduled_action_batch, substream_id}, ctx, %State{} = state) do
    %State.Substream{} = substream = state.substreams[substream_id]

    {oldest_action_batch, rest_of_action_batches} =
      Qex.pop!(substream.action_batches_queue)

    queued_actions = Enum.reverse(oldest_action_batch.actions)

    demand_action =
      calculate_buffered_stream_duration(state)
      |> maybe_demand(ctx, state)

    substream = %State.Substream{substream | action_batches_queue: rest_of_action_batches}
    state = put_in(state.substreams[substream_id], substream)

    {queued_actions ++ demand_action, state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, %State{} = state) do
    {[], %State{state | initialize_new_substream: true}}
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
  def handle_stream_format(:input, stream_format, _ctx, %State{} = state) do
    maybe_queue_action({:stream_format, {:output, stream_format}}, state)
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    lock_offset_if_still_calculating(state)
    maybe_queue_action({:end_of_stream, :output}, state)
  end

  @spec maybe_initialize_new_substream(Time.t(), State.t()) :: State.t()
  defp maybe_initialize_new_substream(
         _buffer_timestamp,
         %State{initialize_new_substream: false} = state
       ) do
    state
  end

  defp maybe_initialize_new_substream(
         buffer_timestamp,
         %State{initialize_new_substream: true} = state
       ) do
    absolute_reference_timestamp =
      if state.substreams == %{} do
        Time.monotonic_time()
      else
        previous_reference_timestamps =
          state.substreams[state.current_substream_id].reference_timestamps

        previous_substream_total_duration =
          state.newest_timestamp - previous_reference_timestamps.stream

        previous_reference_timestamps.absolute + previous_substream_total_duration
      end

    substream = %State.Substream{
      reference_timestamps: %{
        absolute: absolute_reference_timestamp,
        stream: buffer_timestamp
      }
    }

    %State{
      state
      | initialize_new_substream: false,
        current_substream_id: state.current_substream_id + 1,
        substreams: Map.put(state.substreams, state.current_substream_id + 1, substream)
    }
  end

  @spec calculate_buffered_stream_duration(State.t()) :: Membrane.Time.t()
  defp calculate_buffered_stream_duration(state) do
    Enum.sum_by(state.substreams, fn {_substream_id, substream} ->
      case {Qex.last(substream.action_batches_queue), Qex.first(substream.action_batches_queue)} do
        {:empty, :empty} ->
          0

        {{:value, latest_action_batch}, {:value, oldest_action_batch}} ->
          latest_action_batch.timestamp - oldest_action_batch.timestamp
      end
    end)
  end

  @spec maybe_demand(Time.t(), Membrane.Element.CallbackContext.t(), State.t()) ::
          [Membrane.Element.Action.demand()]
  defp maybe_demand(buffered_stream_duration, ctx, state) do
    if ctx.pads.input.end_of_stream? or ctx.pads.input.manual_demand_size > 0 or
         buffered_stream_duration > state.max_latency do
      []
    else
      [demand: :input]
    end
  end

  @spec maybe_schedule_action_batch(Time.t(), non_neg_integer(), State.t()) :: reference() | nil
  defp maybe_schedule_action_batch(_buffer_timestamp, _substream_id, %State{offset: :calculating}) do
    nil
  end

  defp maybe_schedule_action_batch(buffer_timestamp, substream_id, state) do
    substream = state.substreams[substream_id]

    buffer_relative_timestamp =
      buffer_timestamp - substream.reference_timestamps.stream

    target_time =
      substream.reference_timestamps.absolute + buffer_relative_timestamp + state.offset

    send_after_time =
      (target_time - Time.monotonic_time())
      |> max(0)
      |> Time.as_milliseconds(:round)

    Process.send_after(
      self(),
      {:send_scheduled_action_batch, substream_id},
      send_after_time
    )
  end

  @spec lock_offset_if_still_calculating(State.t()) :: State.t()
  defp lock_offset_if_still_calculating(%State{} = state) do
    if state.offset == :calculating do
      state = %State{state | offset: Time.monotonic_time() - state.start_of_stream_time}

      Enum.each(state.substreams, fn {substream_id, substream} ->
        Enum.each(
          substream.action_batches_queue,
          &maybe_schedule_action_batch(&1.timestamp, substream_id, state)
        )
      end)

      state
    else
      state
    end
  end

  @spec maybe_queue_action(Membrane.Element.Action.t(), State.t()) ::
          {[Membrane.Element.Action.t()], State.t()}
  defp maybe_queue_action(action, state) do
    if state.substreams == %{} do
      {[action], state}
    else
      case Qex.pop_back(state.substreams[state.current_substream_id].action_batches_queue) do
        {:empty, _queue} ->
          {[action], state}

        {{:value, latest_action_batch}, action_batches_queue} ->
          latest_action_batch = update_in(latest_action_batch.actions, &[action | &1])

          action_batches_queue = Qex.push(action_batches_queue, latest_action_batch)

          state =
            put_in(
              state.substreams[state.current_substream_id].action_batches_queue,
              action_batches_queue
            )

          {[], state}
      end
    end
  end
end
