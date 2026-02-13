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

  def_options latency: [
                spec: Time.non_neg(),
                default: 0,
                inspector: &Time.inspect/1,
                description: """
                Artificial latency that this element will add to the stream. The purpose of this it
                to handle cases where the incoming stream can get lagged, for example when an
                element up the pipeline can get held up for some time and then produce all the
                "late" buffers at once. The latency gives Realtimer some margin in waiting
                for those "late" buffers, so that the outgoing stream is still smooth.
                """
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            max_latency: Time.non_neg(),
            current_substream_id: non_neg_integer(),
            offset: Time.non_neg() | :calculating,
            substreams: %{
              non_neg_integer() =>
                %{
                  oldest_queued_timestamp: Time.non_neg(),
                  newest_queued_timestamp: Time.non_neg(),
                  reference_timestamps: %{
                    absolute: Time.non_neg(),
                    stream: Time.non_neg()
                  },
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
                  substreams: %{0 => :to_be_initialized},
                  offset: :calculating
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %State{max_latency: opts.latency}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: :input], state}
  end

  # max_latency indicates how much duration the realtimer should buffer.
  # when the first buffer arrives we should start calculating the offset and until we do, we should
  # keep demanding buffers.
  # when the realtimer buffers `max_latency` long stream, we set the offset to the time
  # elapsed from receiving the first buffer.
  # if the time elapsed exceeds `max_latency` before enough stream is buffered, we set
  # the offset to `max_latency`.
  # Now we should schedule sending the queued buffers and from now on, we should schedule
  # sending new buffers as they arrive. We also should stop demanding buffers when a buffer arrives,
  # but when a buffer is sent and the queued duration is shorter than `max_latency`
  #
  # when a reset event arrives we should create a new substream and demand until it's
  # is as long as `max_latency`. We should do that in general and keep track if a buffer
  # has been demanded or not.
  #
  # a new substream should have a reference absolute timestamp set to the target_time of the last
  # timestamp of previous substream
  #

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    buffer_timestamp = Buffer.get_dts_or_pts(buffer)
    monotonic_time = Time.monotonic_time()

    substream =
      case state.substreams[state.current_substream_id] do
        :to_be_initialized ->
          if state.offset == :calculating do
            Process.send_after(
              self(),
              {:initial_latency_passed, state.current_substream_id},
              Time.as_milliseconds(state.max_latency, :round)
            )
          end

          absolute_reference_timestamp =
            if state.current_substream_id == 0 do
              monotonic_time
            else
              previous_substream = state.substreams[state.current_substream_id - 1]

              previous_substream_length =
                previous_substream.newest_queued_timestamp -
                  previous_substream.reference_timestamps.stream

              previous_substream.reference_timestamps.absolute + previous_substream_length
            end

          %{
            oldest_queued_timestamp: buffer_timestamp,
            newest_queued_timestamp: buffer_timestamp,
            reference_timestamps: %{
              absolute: absolute_reference_timestamp,
              stream: buffer_timestamp
            },
            action_batches_queue: [
              %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}
            ]
          }

        initialized_substream ->
          %{
            initialized_substream
            | newest_queued_timestamp: buffer_timestamp,
              action_batches_queue: [
                %{timestamp: buffer_timestamp, actions: [buffer: {:output, buffer}]}
                | initialized_substream.action_batches_queue
              ]
          }
      end

    substream =
      if substream.oldest_queued_timestamp == nil do
        %{substream | oldest_queued_timestamp: buffer_timestamp}
      else
        substream
      end

    substream_duration = substream.newest_queued_timestamp - substream.oldest_queued_timestamp

    demand_action =
      if substream_duration < state.max_latency do
        [demand: :input]
      else
        []
      end

    state =
      if state.offset == :calculating do
        if substream_duration >= state.max_latency do
          state = %State{state | offset: monotonic_time - substream.reference_timestamps.absolute}

          IO.inspect("xx")

          Enum.each(
            substream.action_batches_queue,
            &schedule_next_pop(&1.timestamp, state.offset, substream, state.current_substream_id)
          )

          state
        else
          state
        end
      else
        IO.inspect("cc")
        schedule_next_pop(buffer_timestamp, state.offset, substream, state.current_substream_id)
        state
      end

    #
    # {demand_action, state} =
    #   cond do
    #     state.offset == :calculating and substream_duration < state.max_latency ->
    #       {[demand: :input], state}
    #
    #     state.offset == :calculating and substream_duration >= state.max_latency ->
    #       # accumulated substream longer than max_latency,
    #       # set offset to the elapsed time from absolute reference
    #       state = %State{state | offset: monotonic_time - substream.reference_timestamps.absolute}
    #
    #       Enum.each(
    #         substream.action_batches_queue,
    #         &schedule_next_pop(&1.timestamp, state.offset, substream, state.current_substream_id)
    #       )
    #
    #       {[], state}
    #
    #     state.offset != :calculating and substream_duration < state.max_latency ->
    #       schedule_next_pop(buffer_timestamp, state.offset, substream, state.current_substream_id)
    #       {[demand: :input], state}
    #
    #     state.offset != :calculating and substream_duration >= state.max_latency ->
    #       schedule_next_pop(buffer_timestamp, state.offset, substream, state.current_substream_id)
    #       {[], state}
    #   end

    IO.inspect(buffer, label: "handle_buffer buffer")

    state = put_in(state.substreams[state.current_substream_id], substream)

    IO.inspect(state.substreams, label: "substream")

    {demand_action, state}
  end

  defp schedule_next_pop(buffer_timestamp, offset, substream, current_substream_id) do
    buffer_relative_timestamp =
      buffer_timestamp - substream.reference_timestamps.stream

    target_time =
      substream.reference_timestamps.absolute + buffer_relative_timestamp + offset

    interval =
      (target_time - Time.monotonic_time())
      |> max(0)
      |> Time.as_milliseconds(:round)

    IO.inspect(interval, label: "interval")
    IO.inspect(current_substream_id, label: "scheduled id")

    Process.send_after(
      self(),
      {:pop_action_batches_queue, current_substream_id},
      interval
    )
  end

  @impl true
  def handle_info({:initial_latency_passed, substream_id}, _ctx, %State{} = state) do
    # exceeded max latency, set substream offset to max_latency
    substream = state.substreams[substream_id]

    offset =
      if state.offset == :calculating do
        Enum.each(
          substream.action_batches_queue,
          &schedule_next_pop(
            &1.timestamp,
            state.max_latency,
            substream,
            state.current_substream_id
          )
        )

        state.max_latency
      else
        state.offset
      end

    {[], %State{state | offset: offset}}
  end

  @impl true
  def handle_info({:pop_action_batches_queue, substream_id}, ctx, %State{} = state) do
    substream = state.substreams[substream_id]

    {oldest_action_batch, rest_of_action_batches} =
      List.pop_at(substream.action_batches_queue, -1)

    actions =
      Enum.reverse(oldest_action_batch.actions) |> IO.inspect(label: "oldest_action_batch")

    {oldest_queued_timestamp, substream_duration} =
      case Enum.at(rest_of_action_batches, -1) do
        nil ->
          {nil, 0}

        oldest_action_batch ->
          substream_duration =
            substream.newest_queued_timestamp - oldest_action_batch.timestamp

          {oldest_action_batch.timestamp, substream_duration}
      end

    substream = %{
      substream
      | oldest_queued_timestamp: oldest_queued_timestamp,
        action_batches_queue: rest_of_action_batches
    }

    IO.inspect(ctx.pads.input.manual_demand_size, label: "ctx")

    demand_action =
      if ctx.pads.input.end_of_stream? or ctx.pads.input.manual_demand_size > 0 or
           substream_duration > state.max_latency do
        []
      else
        [demand: :input]
      end

    state = put_in(state.substreams[substream_id], substream)

    {actions ++ demand_action, state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, %State{} = state) do
    IO.inspect("reset")
    new_substream_id = state.current_substream_id + 1

    state = update_in(state.substreams, &Map.put(&1, new_substream_id, :to_be_initialized))
    state = put_in(state.current_substream_id, new_substream_id)

    {[], state}
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
