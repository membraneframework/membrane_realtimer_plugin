defmodule Membrane.RealtimerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Realtimer, Testing, Time}
  alias Membrane.Realtimer.Events.Reset

  test "Limits playback speed to realtime" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(100), payload: 1}},
        end_of_stream: :output
      ]
    ]

    assertions_fun = fn pipeline ->
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
      refute_sink_buffer(pipeline, :sink, _buffer, 90)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
      assert_end_of_stream(pipeline, :sink)
    end

    test_scenario(action_batches, 0, assertions_fun)
  end

  test "Limits playback to realtime with introduced initial latency" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(100), payload: 1}},
        end_of_stream: :output
      ]
    ]

    assertions_fun = fn pipeline ->
      refute_sink_buffer(pipeline, :sink, _buffer, 190)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
      refute_sink_buffer(pipeline, :sink, _buffer, 90)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
      assert_end_of_stream(pipeline, :sink)
    end

    test_scenario(action_batches, Time.milliseconds(200), assertions_fun)
  end

  test "Starts following the time of the first buffer" do
    action_batches = [
      [
        buffer: {:output, %Buffer{pts: Time.seconds(10), payload: 0}},
        end_of_stream: :output
      ]
    ]

    assertions_fun = fn pipeline ->
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 200)
      assert_end_of_stream(pipeline, :sink)
    end

    test_scenario(action_batches, 0, assertions_fun)
  end

  test "Correctly reacts to Reset event" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(100), payload: 1}},
        event: {:output, %Reset{}}
      ],
      [buffer: {:output, %Buffer{pts: Time.milliseconds(800), payload: 2}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(900), payload: 3}},
        end_of_stream: :output
      ]
    ]

    assertions_fun = fn pipeline ->
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
      refute_sink_buffer(pipeline, :sink, _buffer, 90)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
      refute_sink_buffer(pipeline, :sink, _buffer, 90)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
      assert_end_of_stream(pipeline, :sink)
    end

    test_scenario(action_batches, 0, assertions_fun)
  end

  test "Correctly reacts to Reset event with latency set" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(200), payload: 1}},
        event: {:output, %Reset{}}
      ],
      [buffer: {:output, %Buffer{pts: Time.milliseconds(400), payload: 2}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(600), payload: 3}},
        end_of_stream: :output
      ]
    ]

    assertions_fun = fn pipeline ->
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
      refute_sink_buffer(pipeline, :sink, _buffer, 190)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
      refute_sink_buffer(pipeline, :sink, _buffer, 190)
      assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
      assert_end_of_stream(pipeline, :sink)
    end

    test_scenario(action_batches, Time.milliseconds(200), assertions_fun)
  end

  test "Corretly reacts to realtime input with max_latency set" do
    instructions = [
      {:buffer, %Buffer{pts: 0, payload: 0}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(200), payload: 1}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(400), payload: 2}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(600), payload: 3}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(800), payload: 4}}
    ]

    spec =
      child(:src, %Membrane.Realtimer.TimedSource{instructions: instructions})
      |> child(:realtimer, %Realtimer{max_latency: Time.milliseconds(500)})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_stream_format(pipeline, :sink, _stream_format)
    refute_sink_buffer(pipeline, :sink, _buffer, 490)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 4}, 20)
    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline)
  end

  test "Correctly reacts to laggy realtime input" do
    instructions = [
      {:buffer, %Buffer{pts: 0, payload: 0}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(200), payload: 1}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(400), payload: 2}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(600), payload: 3}},
      {:sleep, Time.milliseconds(400)},
      {:buffer, %Buffer{pts: Time.milliseconds(800), payload: 4}},
      {:buffer, %Buffer{pts: Time.milliseconds(1000), payload: 5}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(1200), payload: 6}}
    ]

    spec =
      child(:src, %Membrane.Realtimer.TimedSource{instructions: instructions})
      |> child(:realtimer, %Realtimer{max_latency: Time.milliseconds(500)})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_stream_format(pipeline, :sink, _stream_format)
    refute_sink_buffer(pipeline, :sink, _buffer, 490)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 4}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 5}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 6}, 20)
    assert_end_of_stream(pipeline, :sink)

    Testing.Pipeline.terminate(pipeline)
  end

  test "Correctly reacts to laggy non-realtime input" do
    instructions = [
      {:buffer, %Buffer{pts: 0, payload: 0}},
      {:buffer, %Buffer{pts: Time.milliseconds(200), payload: 1}},
      {:buffer, %Buffer{pts: Time.milliseconds(400), payload: 2}},
      {:buffer, %Buffer{pts: Time.milliseconds(600), payload: 3}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(800), payload: 4}},
      {:sleep, Time.milliseconds(400)},
      {:buffer, %Buffer{pts: Time.milliseconds(1000), payload: 5}}
    ]

    spec =
      child(:src, %Membrane.Realtimer.TimedSource{instructions: instructions})
      |> child(:realtimer, %Realtimer{max_latency: Time.milliseconds(500)})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_stream_format(pipeline, :sink, _stream_format)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 4}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 5}, 20)
    assert_end_of_stream(pipeline, :sink)
  end

  test "Correctly reacts to laggy realtime input with reset events" do
    instructions = [
      {:buffer, %Buffer{pts: 0, payload: 0}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(200), payload: 1}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(400), payload: 2}},
      {:sleep, Time.milliseconds(400)},
      {:buffer, %Buffer{pts: Time.milliseconds(600), payload: 3}},
      {:buffer, %Buffer{pts: Time.milliseconds(800), payload: 4}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(1000), payload: 5}},
      {:event, %Realtimer.Events.Reset{}},
      {:buffer, %Buffer{pts: 0, payload: 6}},
      {:sleep, Time.milliseconds(200)},
      {:buffer, %Buffer{pts: Time.milliseconds(200), payload: 7}},
      {:sleep, Time.milliseconds(400)},
      {:buffer, %Buffer{pts: Time.milliseconds(400), payload: 8}},
      {:buffer, %Buffer{pts: Time.milliseconds(600), payload: 9}}
    ]

    spec =
      child(:src, %Membrane.Realtimer.TimedSource{instructions: instructions})
      |> child(:realtimer, %Realtimer{max_latency: Time.milliseconds(500)})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_stream_format(pipeline, :sink, _stream_format)
    refute_sink_buffer(pipeline, :sink, _buffer, 490)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 4}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 5}, 20)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 6}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 7}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 8}, 20)
    assert_end_of_stream(pipeline, :sink)
  end

  defp test_scenario(action_batches, max_latency, assertions_fun) do
    generator_fun = fn action_batches_left, demand ->
      Enum.split(List.flatten(action_batches_left), demand)
    end

    spec =
      child(:src, %Testing.Source{output: {action_batches, generator_fun}})
      |> child(:realtimer, %Realtimer{max_latency: max_latency})
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assertions_fun.(pipeline)
    Testing.Pipeline.terminate(pipeline)
  end
end
