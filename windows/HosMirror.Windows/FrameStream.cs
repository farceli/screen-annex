using System;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;

namespace HosMirror.Windows;

/// <summary>
/// Blocking stream fed by the native frame callback. LibVLC's raw H.264 demuxer
/// pulls from this stream, so back-pressure is handled by the bounded queue.
/// </summary>
internal sealed class FrameStream : Stream
{
    private readonly BlockingCollection<byte[]> _queue =
        new(new ConcurrentQueue<byte[]>(), 180);
    private readonly CancellationTokenSource _completion = new(); // 取消正在等待队列空位的原生回调。
    private byte[]? _current;
    private int _offset;

    public void Push(byte[] data)
    {
        try
        {
            if (!_queue.IsAddingCompleted)
            {
                _queue.Add(data, _completion.Token); // Complete 必须能唤醒满队列上的生产者。
            }
        }
        catch (OperationCanceledException)
        {
            // 停止时放弃尚未入队的帧，允许原生读取线程立即退出。
        }
        catch (InvalidOperationException)
        {
            // Completed.
        }
    }

    public void Complete()
    {
        _completion.Cancel(); // 必须先取消 Add，再 CompleteAdding，避免等待仍阻塞的生产者。
        try { _queue.CompleteAdding(); } catch (InvalidOperationException) { } // 重复关闭安全。
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        if (count == 0) return 0; // Stream 约定零字节读取不能等待数据。
        if (_current is null || _offset >= _current.Length)
        {
            try
            {
                if (!_queue.TryTake(out _current, Timeout.Infinite, _completion.Token)) return 0; // 队列完成后返回 EOF。
            }
            catch (OperationCanceledException)
            {
                return 0; // 停止时也唤醒等待新帧的 VLC 读取线程。
            }
            _offset = 0;
        }

        int available = _current!.Length - _offset;
        int copied = Math.Min(available, count);
        Array.Copy(_current, _offset, buffer, offset, copied);
        _offset += copied;
        return copied;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _queue.Dispose(); // 调用方必须先等原生回调和播放器退出。
            _completion.Dispose();
        }
        base.Dispose(disposing);
    }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
