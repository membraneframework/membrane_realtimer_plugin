defmodule Membrane.Realtimer do
  @moduledoc """
  Sends buffers to the output in real time, according to buffers' timestamps.

  If buffers come in slower than realtime, they're sent as they come in.

  It can be reset by sending `%#{inspect(__MODULE__)}.Events.Reset{}` event on its input pad.
  """
  use Membrane.Filter

  alias __MODULE__.Events
  alias Membrane.Buffer

  def_input_pad :input, accepted_format: _any, flow_control: :manual, demand_unit: :buffers
  def_output_pad :output, accepted_format: _any, flow_control: :push

  def_options latency: [
                spec: Membrane.Time.non_neg(),
                default: 0,
                description: """
                Inital latency lol
                """
              ]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            reference_time: Membrane.Time.non_neg() | nil,
            reference_timestamp: Membrane.Time.non_neg() | nil,
            tick_actions: [Membrane.Element.Action.t()],
            timer_status: :to_be_started | :running | :to_be_stopped
          }

    @enforce_keys [:latency]

    defstruct @enforce_keys ++
                [
                  reference_time: nil,
                  reference_timestamp: nil,
                  tick_actions: [],
                  timer_status: :to_be_started
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[], %State{latency: opts.latency}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: :input], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state = %State{}) do
    {maybe_start_timer, state} =
      if state.timer_status == :to_be_started do
        {
          [start_timer: {:timer, :no_interval}],
          %State{
            state
            | timer_status: :running,
              reference_time: Membrane.Time.monotonic_time(),
              reference_timestamp: Buffer.get_dts_or_pts(buffer)
          }
        }
      else
        {[], state}
      end

    time_from_reference_time = Buffer.get_dts_or_pts(buffer) - state.reference_timestamp

    target_time = state.reference_time + time_from_reference_time + state.latency

    interval = max(target_time - Membrane.Time.monotonic_time(), 0)

    state = %State{
      state
      | tick_actions: [buffer: {:output, buffer}] ++ state.tick_actions
    }

    {maybe_start_timer ++ [timer_interval: {:timer, interval}], state}
  end

  @impl true
  def handle_event(:input, %Events.Reset{}, _ctx, %State{} = state) do
    case state.tick_actions do
      [] when state.timer_status == :to_be_started ->
        {[], state}

      [] when state.timer_status == :running ->
        {[stop_timer: :timer], %State{state | timer_status: :to_be_started}}

      _many ->
        {[], %State{state | timer_status: :to_be_stopped}}
    end
  end

  @impl true
  def handle_event(pad, event, _ctx, %State{tick_actions: tick_actions} = state)
      when pad == :output or tick_actions == [] do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, %State{} = state) do
    {[], %State{state | tick_actions: [event: {:output, event}] ++ state.tick_actions}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{tick_actions: []} = state) do
    {[forward: stream_format], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{} = state) do
    {[],
     %State{state | tick_actions: [stream_format: {:output, stream_format}] ++ state.tick_actions}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{tick_actions: []} = state) do
    {[end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %State{} = state) do
    {[], %State{state | tick_actions: [end_of_stream: :output] ++ state.tick_actions}}
  end

  @impl true
  def handle_tick(:timer, ctx, %State{} = state) do
    actions =
      [timer_interval: {:timer, :no_interval}] ++
        Enum.reverse(state.tick_actions) ++
        if ctx.pads.input.end_of_stream?, do: [], else: [demand: :input]

    {maybe_stop_timer, state} =
      case state.timer_status do
        :to_be_stopped -> {[stop_timer: :timer], %State{state | timer_status: :to_be_started}}
        :running -> {[], state}
      end

    {actions ++ maybe_stop_timer, %State{state | tick_actions: []}}
  end
end
