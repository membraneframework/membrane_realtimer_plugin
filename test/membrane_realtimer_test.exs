defmodule Membrane.RealtimerTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{Buffer, Realtimer, Testing, Time}

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

    refute_sink_buffer(pipeline, :sink, _buffer, 190)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 0})
    refute_sink_buffer(pipeline, :sink, _buffer, 90)
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: 1}, 20)
    assert_end_of_stream(pipeline, :sink)
    refute_sink_buffer(pipeline, :sink, _buffer, 0)
    Testing.Pipeline.terminate(pipeline)
  end

  test "Start following the time of the first buffer" do
    import Membrane.ChildrenSpec

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
end
