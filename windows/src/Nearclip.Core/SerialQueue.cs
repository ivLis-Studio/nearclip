using System.Collections.Concurrent;

namespace Nearclip.Core;

/// <summary>A dedicated thread that runs posted actions one at a time, in order (like a serial dispatch queue).</summary>
public sealed class SerialQueue : IDisposable
{
    readonly BlockingCollection<Action> _items = new();
    readonly Thread _thread;
    [ThreadStatic] static SerialQueue? s_current;

    public Action<Exception>? OnError { get; set; }

    public SerialQueue(string name)
    {
        _thread = new Thread(Run) { IsBackground = true, Name = name };
        _thread.Start();
    }

    void Run()
    {
        s_current = this;
        foreach (var action in _items.GetConsumingEnumerable())
        {
            try { action(); }
            catch (Exception e) { OnError?.Invoke(e); }
        }
    }

    public bool IsCurrent => s_current == this;

    public void Post(Action action)
    {
        try { _items.Add(action); }
        catch (InvalidOperationException) { /* shut down */ }
    }

    public void After(TimeSpan delay, Action action) =>
        _ = Task.Delay(delay).ContinueWith(_ => Post(action), TaskScheduler.Default);

    public T Invoke<T>(Func<T> func)
    {
        if (IsCurrent) return func();
        return InvokeAsync(func).GetAwaiter().GetResult();
    }

    public void Invoke(Action action) => Invoke(() => { action(); return 0; });

    public Task<T> InvokeAsync<T>(Func<T> func)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() =>
        {
            try { tcs.SetResult(func()); }
            catch (Exception e) { tcs.SetException(e); }
        });
        if (_items.IsAddingCompleted && !tcs.Task.IsCompleted) tcs.TrySetCanceled();
        return tcs.Task;
    }

    /// <summary>Lets queued work finish, then stops the thread.</summary>
    public void Dispose()
    {
        _items.CompleteAdding();
        if (!IsCurrent) _thread.Join(TimeSpan.FromSeconds(5));
    }
}
