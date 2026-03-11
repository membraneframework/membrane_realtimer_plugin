defmodule Membrane.Realtimer.TimedSource do
  @moduledoc false
  use Membrane.Source

  alias Membrane.{Buffer, Time}
  alias Membrane.Realtimer.Events.Reset

  @type instruction ::
          {:buffer, pts_ms :: integer()}
          | :reset
          | {:sleep, duration_ms :: non_neg_integer()}

  def_output_pad :output, accepted_format: _any, flow_control: :push

  def_options instructions: [
                spec: [instruction()]
              ]

  @impl true
  def handle_init(_ctx, opts) do
    instructions =
      Enum.map(opts.instructions, fn
        {:buffer, {payload, pts}} ->
          {:buffer, {:output, %Buffer{payload: payload, pts: Time.milliseconds(pts)}}}

        {:event, :reset} ->
          {:event, {:output, %Reset{}}}

        {:sleep, time} ->
          {:sleep, Time.milliseconds(time)}
      end)

    {[], %{instructions: instructions}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {actions, rest_of_instructions} = get_actions_to_execute(state.instructions)

    {
      [stream_format: {:output, %Membrane.RemoteStream{}}] ++ actions,
      %{state | instructions: rest_of_instructions}
    }
  end

  @impl true
  def handle_info(:sleep_finished, _ctx, state) do
    {actions, rest_of_instructions} = get_actions_to_execute(state.instructions)

    {actions, %{state | instructions: rest_of_instructions}}
  end

  defp get_actions_to_execute(instructions) do
    {actions_to_execute, rest_of_instructions} =
      Enum.split_while(instructions, fn
        {:sleep, _time} -> false
        _other -> true
      end)

    {maybe_eos, rest_of_instructions} =
      case rest_of_instructions do
        [{:sleep, sleep_duration} | rest_of_instructions] ->
          Process.send_after(
            self(),
            :sleep_finished,
            Membrane.Time.as_milliseconds(sleep_duration, :round)
          )

          {[], rest_of_instructions}

        [] ->
          {[end_of_stream: :output], []}
      end

    {actions_to_execute ++ maybe_eos, rest_of_instructions}
  end
end
