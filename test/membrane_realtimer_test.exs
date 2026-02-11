defmodule Membrane.RealtimerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Realtimer, Testing, Time}
  alias Membrane.Realtimer.Events.Reset

  test "Limits playback speed to realtime" do
    buffers = [
      %Buffer{pts: 0, payload: 0},
      %Buffer{pts: Time.milliseconds(100), payload: 1}
    ]

    spec = [
      child(:src, %Testing.Source{output: Testing.Source.output_from_buffers(buffers)})
      |> child(:realtimer, Realtimer)
      |> child(:sink, Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)
    Testing.Pipeline.terminate(pipeline)
  end

  test "Limits playback to realtime with introduced initial latency" do
    buffers = [
      %Buffer{pts: 0, payload: 0},
      %Buffer{pts: Time.milliseconds(100), payload: 1}
    ]

    spec = [
      child(:src, %Testing.Source{output: Testing.Source.output_from_buffers(buffers)})
      |> child(:realtimer, %Realtimer{latency: Time.milliseconds(200)})
      |> child(:sink, Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)

    refute_sink_buffer(pipeline, :sink, _buffer, 200)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)
    Testing.Pipeline.terminate(pipeline)
  end

  test "Starts following the time of the first buffer" do
    buffers = [
      %Buffer{pts: Time.seconds(10), payload: 0}
    ]

    spec = [
      child(:src, %Testing.Source{output: Testing.Source.output_from_buffers(buffers)})
      |> child(:realtimer, Realtimer)
      |> child(:sink, Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 200)
    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end

  test "Correctly reacts to Reset event" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(100), payload: 1}},
        event: {:output, %Reset{}}
      ],
      [buffer: {:output, %Buffer{pts: Time.milliseconds(200), payload: 2}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(300), payload: 3}},
        end_of_stream: :output
      ]
    ]

    generator_fun = fn action_batches_left, demand ->
      Enum.split(List.flatten(action_batches_left), demand)
    end

    spec = [
      child(:src, %Testing.Source{output: {action_batches, generator_fun}})
      |> child(:realtimer, Realtimer)
      |> child(:sink, Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end

  test "Correctly reacts to Reset event with latency set" do
    action_batches = [
      [buffer: {:output, %Buffer{pts: 0, payload: 0}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(100), payload: 1}},
        event: {:output, %Reset{}}
      ],
      [buffer: {:output, %Buffer{pts: Time.milliseconds(200), payload: 2}}],
      [
        buffer: {:output, %Buffer{pts: Time.milliseconds(300), payload: 3}},
        end_of_stream: :output
      ]
    ]

    generator_fun = fn action_batches_left, demand ->
      Enum.split(List.flatten(action_batches_left), demand)
    end

    spec = [
      child(:src, %Testing.Source{output: {action_batches, generator_fun}})
      |> child(:realtimer, %Realtimer{latency: Time.milliseconds(200)})
      |> child(:sink, Testing.Sink)
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    refute_sink_buffer(pipeline, :sink, _buffer, 200)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 200)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 2}, 20)
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 3}, 20)
    assert_end_of_stream(pipeline, :sink)
    Testing.Pipeline.terminate(pipeline)
  end
end
