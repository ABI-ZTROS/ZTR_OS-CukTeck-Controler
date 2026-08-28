using System;
using System.Windows.Input;

namespace CukTechController.ViewModels;

/// <summary>
/// 通用 ICommand 实现（同步 + 异步）
/// </summary>
public class RelayCommand : ICommand
{
    private readonly Func<Task>? _executeAsync;
    private readonly Action? _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Func<Task> executeAsync, Func<bool>? canExecute = null)
    {
        _executeAsync = executeAsync;
        _canExecute = canExecute;
    }

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public async void Execute(object? parameter)
    {
        if (_executeAsync != null) await _executeAsync();
        else _execute?.Invoke();
    }

    public event EventHandler? CanExecuteChanged
    {
        add { CommandManager.RequerySuggested += value; }
        remove { CommandManager.RequerySuggested -= value; }
    }
}

/// <summary>
/// 通用泛型 ICommand 实现
/// </summary>
public class RelayCommand<T> : ICommand
{
    private readonly Func<T, Task>? _executeAsync;
    private readonly Action<T>? _execute;
    private readonly Predicate<T>? _canExecute;

    public RelayCommand(Func<T, Task> executeAsync, Predicate<T>? canExecute = null)
    {
        _executeAsync = executeAsync;
        _canExecute = canExecute;
    }

    public RelayCommand(Action<T> execute, Predicate<T>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public bool CanExecute(object? parameter) => _canExecute?.Invoke((T)parameter!) ?? true;

    public async void Execute(object? parameter)
    {
        if (_executeAsync != null) await _executeAsync((T)parameter!);
        else _execute?.Invoke((T)parameter!);
    }

    public event EventHandler? CanExecuteChanged
    {
        add { CommandManager.RequerySuggested += value; }
        remove { CommandManager.RequerySuggested -= value; }
    }
}
