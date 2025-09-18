defmodule Membrane.Realtimer do
  @moduledoc """
  Sends buffers to the output in real time, according to buffers' timestamps.

  If buffers come in slower than realtime, they're sent as they come in.

  It can be reset by sending `%#{inspect(__MODULE__)}.Events.Reset{}` event on its input pad.

  It can also handle flushing mode - when it receives `:enter_flushing_mode` notification from its parent,
  it immediately forwards everything as it comes in, without looking at timestamps.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.Events
  alias Membrane.Buffer

  def_input_pad :input, accepted_format: _any, flow_control: :manual, demand_unit: :buffers
  def_output_pad :output, accepted_format: _any, flow_control: :push

  @impl true
  def handle_init(_ctx, _opts) do
    {[],
     %{
       previous_timestamp: nil,
       tick_actions: [],
       timer_status: :to_be_started,
       flushing_mode?: false
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, 1}], state}
  end

  @impl true
  def handle_parent_notification(:enter_flushing_mode, ctx, state) do
    Membrane.Logger.debug("Entering flushing mode")

    {flushed_actions, state} = flush_tick_actions(ctx, state)

    maybe_stop_timer =
      if state.timer_status == :running, do: [stop_timer: :timer], else: []

    state = %{state | flushing_mode?: true, timer_status: :to_be_started}
    {flushed_actions ++ maybe_stop_timer, state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) when not state.flushing_mode? do
    {maybe_start_timer, state} =
      if state.timer_status == :to_be_started,
        do: {[start_timer: {:timer, :no_interval}], %{state | timer_status: :running}},
        else: {[], state}

    state =
      with %{previous_timestamp: nil} <- state do
        %{state | previous_timestamp: Buffer.get_dts_or_pts(buffer) || 0}
      end

    interval = Buffer.get_dts_or_pts(buffer) - state.previous_timestamp

    state = %{
      state
      | previous_timestamp: Buffer.get_dts_or_pts(buffer),
        tick_actions: [buffer: {:output, buffer}] ++ state.tick_actions
    }

    {maybe_start_timer ++ [timer_interval: {:timer, interval}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) when state.flushing_mode? do
    {[buffer: {:output, buffer}, demand: {:input, 1}], state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, state) do
    {actions, state} =
      case state.tick_actions do
        [] when state.timer_status == :to_be_started ->
          {[], state}

        [] when state.timer_status == :running ->
          {[stop_timer: :timer], %{state | timer_status: :to_be_started}}

        _many ->
          {[], %{state | timer_status: :to_be_stopped}}
      end

    {actions, %{state | previous_timestamp: nil}}
  end

  @impl true
  def handle_event(pad, event, _ctx, %{tick_actions: tick_actions} = state)
      when pad == :output or tick_actions == [] do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    {[], %{state | tick_actions: [event: {:output, event}] ++ state.tick_actions}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %{tick_actions: []} = state) do
    {[forward: stream_format], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {[], %{state | tick_actions: [stream_format: {:output, stream_format}] ++ state.tick_actions}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{tick_actions: []} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {[], %{state | tick_actions: [end_of_stream: :output] ++ state.tick_actions}}
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    {actions, state} = flush_tick_actions(ctx, state)

    {maybe_stop_timer, state} =
      case state.timer_status do
        :to_be_stopped -> {[stop_timer: :timer], %{state | timer_status: :to_be_started}}
        :running -> {[], state}
      end

    {actions ++ maybe_stop_timer, %{state | tick_actions: []}}
  end

  defp flush_tick_actions(ctx, state) do
    actions =
      Enum.reverse(state.tick_actions) ++
        if ctx.pads.input.end_of_stream?, do: [], else: [demand: {:input, 1}]

    {actions, %{state | tick_actions: []}}
  end
end
