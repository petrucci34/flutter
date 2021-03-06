// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'basic.dart';
import 'focus_manager.dart';
import 'focus_scope.dart';
import 'framework.dart';
import 'modal_barrier.dart';
import 'navigator.dart';
import 'overlay.dart';
import 'page_storage.dart';
import 'pages.dart';

const Color _kTransparent = const Color(0x00000000);

/// A route that displays widgets in the [Navigator]'s [Overlay].
abstract class OverlayRoute<T> extends Route<T> {
  /// Subclasses should override this getter to return the builders for the overlay.
  Iterable<OverlayEntry> createOverlayEntries();

  /// The entries this route has placed in the overlay.
  @override
  List<OverlayEntry> get overlayEntries => _overlayEntries;
  final List<OverlayEntry> _overlayEntries = <OverlayEntry>[];

  @override
  void install(OverlayEntry insertionPoint) {
    assert(_overlayEntries.isEmpty);
    _overlayEntries.addAll(createOverlayEntries());
    navigator.overlay?.insertAll(_overlayEntries, above: insertionPoint);
    super.install(insertionPoint);
  }

  /// Controls whether [didPop] calls [NavigatorState.finalizeRoute].
  ///
  /// If true, this route removes its overlay entries during [didPop].
  /// Subclasses can override this getter if they want to delay finalization
  /// (for example to animate the route's exit before removing it from the
  /// overlay).
  ///
  /// Subclasses that return false from [finishedWhenPopped] are responsible for
  /// calling [NavigatorState.finalizeRoute] themselves.
  @protected
  bool get finishedWhenPopped => true;

  @override
  bool didPop(T result) {
    final bool returnValue = super.didPop(result);
    assert(returnValue);
    if (finishedWhenPopped)
      navigator.finalizeRoute(this);
    return returnValue;
  }

  @override
  void dispose() {
    for (OverlayEntry entry in _overlayEntries)
      entry.remove();
    _overlayEntries.clear();
    super.dispose();
  }
}

/// A route with entrance and exit transitions.
abstract class TransitionRoute<T> extends OverlayRoute<T> {
  /// This future completes only once the transition itself has finished, after
  /// the overlay entries have been removed from the navigator's overlay.
  ///
  /// This future completes once the animation has been dismissed. That will be
  /// after [popped], because [popped] completes before the animation even
  /// starts, as soon as the route is popped.
  Future<T> get completed => _transitionCompleter.future;
  final Completer<T> _transitionCompleter = new Completer<T>();

  /// The duration the transition lasts.
  Duration get transitionDuration;

  /// Whether the route obscures previous routes when the transition is complete.
  ///
  /// When an opaque route's entrance transition is complete, the routes behind
  /// the opaque route will not be built to save resources.
  bool get opaque;

  @override
  bool get finishedWhenPopped => _controller.status == AnimationStatus.dismissed;

  /// The animation that drives the route's transition and the previous route's
  /// forward transition.
  Animation<double> get animation => _animation;
  Animation<double> _animation;

  /// The animation controller that the route uses to drive the transitions.
  ///
  /// The animation itself is exposed by the [animation] property.
  @protected
  AnimationController get controller => _controller;
  AnimationController _controller;

  /// Called to create the animation controller that will drive the transitions to
  /// this route from the previous one, and back to the previous route from this
  /// one.
  AnimationController createAnimationController() {
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    final Duration duration = transitionDuration;
    assert(duration != null && duration >= Duration.ZERO);
    return new AnimationController(
      duration: duration,
      debugLabel: debugLabel,
      vsync: navigator,
    );
  }

  /// Called to create the animation that exposes the current progress of
  /// the transition controlled by the animation controller created by
  /// [createAnimationController()].
  Animation<double> createAnimation() {
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    assert(_controller != null);
    return _controller.view;
  }

  T _result;

  void _handleStatusChanged(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.completed:
        if (overlayEntries.isNotEmpty)
          overlayEntries.first.opaque = opaque;
        break;
      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        if (overlayEntries.isNotEmpty)
          overlayEntries.first.opaque = false;
        break;
      case AnimationStatus.dismissed:
        assert(!overlayEntries.first.opaque);
        // We might still be the current route if a subclass is controlling the
        // the transition and hits the dismissed status. For example, the iOS
        // back gesture drives this animation to the dismissed status before
        // popping the navigator.
        if (!isCurrent) {
          navigator.finalizeRoute(this);
          assert(overlayEntries.isEmpty);
        }
        break;
    }
  }

  /// The animation for the route being pushed on top of this route. This
  /// animation lets this route coordinate with the entrance and exit transition
  /// of routes pushed on top of this route.
  Animation<double> get secondaryAnimation => _secondaryAnimation;
  final ProxyAnimation _secondaryAnimation = new ProxyAnimation(kAlwaysDismissedAnimation);

  @override
  void install(OverlayEntry insertionPoint) {
    assert(!_transitionCompleter.isCompleted, 'Cannot install a $runtimeType after disposing it.');
    _controller = createAnimationController();
    assert(_controller != null, '$runtimeType.createAnimationController() returned null.');
    _animation = createAnimation();
    assert(_animation != null, '$runtimeType.createAnimation() returned null.');
    super.install(insertionPoint);
  }

  @override
  TickerFuture didPush() {
    assert(_controller != null, '$runtimeType.didPush called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    _animation.addStatusListener(_handleStatusChanged);
    return _controller.forward();
  }

  @override
  void didReplace(Route<dynamic> oldRoute) {
    assert(_controller != null, '$runtimeType.didReplace called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    if (oldRoute is TransitionRoute<dynamic>)
      _controller.value = oldRoute._controller.value;
    _animation.addStatusListener(_handleStatusChanged);
    super.didReplace(oldRoute);
  }

  @override
  bool didPop(T result) {
    assert(_controller != null, '$runtimeType.didPop called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    _result = result;
    _controller.reverse();
    return super.didPop(result);
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    assert(_controller != null, '$runtimeType.didPopNext called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    _updateSecondaryAnimation(nextRoute);
    super.didPopNext(nextRoute);
  }

  @override
  void didChangeNext(Route<dynamic> nextRoute) {
    assert(_controller != null, '$runtimeType.didChangeNext called before calling install() or after calling dispose().');
    assert(!_transitionCompleter.isCompleted, 'Cannot reuse a $runtimeType after disposing it.');
    _updateSecondaryAnimation(nextRoute);
    super.didChangeNext(nextRoute);
  }

  void _updateSecondaryAnimation(Route<dynamic> nextRoute) {
    if (nextRoute is TransitionRoute<dynamic> && canTransitionTo(nextRoute) && nextRoute.canTransitionFrom(this)) {
      final Animation<double> current = _secondaryAnimation.parent;
      if (current != null) {
        if (current is TrainHoppingAnimation) {
          TrainHoppingAnimation newAnimation;
          newAnimation = new TrainHoppingAnimation(
            current.currentTrain,
            nextRoute._animation,
            onSwitchedTrain: () {
              assert(_secondaryAnimation.parent == newAnimation);
              assert(newAnimation.currentTrain == nextRoute._animation);
              _secondaryAnimation.parent = newAnimation.currentTrain;
              newAnimation.dispose();
            }
          );
          _secondaryAnimation.parent = newAnimation;
          current.dispose();
        } else {
          _secondaryAnimation.parent = new TrainHoppingAnimation(current, nextRoute._animation);
        }
      } else {
        _secondaryAnimation.parent = nextRoute._animation;
      }
    } else {
      _secondaryAnimation.parent = kAlwaysDismissedAnimation;
    }
  }

  /// Whether this route can perform a transition to the given route.
  ///
  /// Subclasses can override this method to restrict the set of routes they
  /// need to coordinate transitions with.
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) => true;

  /// Whether this route can perform a transition from the given route.
  ///
  /// Subclasses can override this method to restrict the set of routes they
  /// need to coordinate transitions with.
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => true;

  @override
  void dispose() {
    assert(!_transitionCompleter.isCompleted, 'Cannot dispose a $runtimeType twice.');
    _controller?.dispose();
    _transitionCompleter.complete(_result);
    super.dispose();
  }

  /// A short description of this route useful for debugging.
  String get debugLabel => '$runtimeType';

  @override
  String toString() => '$runtimeType(animation: $_controller)';
}

/// An entry in the history of a [LocalHistoryRoute].
class LocalHistoryEntry {
  /// Creates an entry in the history of a [LocalHistoryRoute].
  LocalHistoryEntry({ this.onRemove });

  /// Called when this entry is removed from the history of its associated [LocalHistoryRoute].
  final VoidCallback onRemove;

  LocalHistoryRoute<dynamic> _owner;

  /// Remove this entry from the history of its associated [LocalHistoryRoute].
  void remove() {
    _owner.removeLocalHistoryEntry(this);
    assert(_owner == null);
  }

  void _notifyRemoved() {
    if (onRemove != null)
      onRemove();
  }
}

/// A route that can handle back navigations internally by popping a list.
///
/// When a [Navigator] is instructed to pop, the current route is given an
/// opportunity to handle the pop internally. A LocalHistoryRoute handles the
/// pop internally if its list of local history entries is non-empty. Rather
/// than being removed as the current route, the most recent [LocalHistoryEntry]
/// is removed from the list and its [LocalHistoryEntry.onRemove] is called.
abstract class LocalHistoryRoute<T> extends Route<T> {
  List<LocalHistoryEntry> _localHistory;

  /// Adds a local history entry to this route.
  ///
  /// When asked to pop, if this route has any local history entries, this route
  /// will handle the pop internally by removing the most recently added local
  /// history entry.
  ///
  /// The given local history entry must not already be part of another local
  /// history route.
  void addLocalHistoryEntry(LocalHistoryEntry entry) {
    assert(entry._owner == null);
    entry._owner = this;
    _localHistory ??= <LocalHistoryEntry>[];
    final bool wasEmpty = _localHistory.isEmpty;
    _localHistory.add(entry);
    if (wasEmpty)
      changedInternalState();
  }

  /// Remove a local history entry from this route.
  ///
  /// The entry's [LocalHistoryEntry.onRemove] callback, if any, will be called
  /// synchronously.
  void removeLocalHistoryEntry(LocalHistoryEntry entry) {
    assert(entry != null);
    assert(entry._owner == this);
    assert(_localHistory.contains(entry));
    _localHistory.remove(entry);
    entry._owner = null;
    entry._notifyRemoved();
    if (_localHistory.isEmpty)
      changedInternalState();
  }

  @override
  Future<RoutePopDisposition> willPop() async {
    if (willHandlePopInternally)
      return RoutePopDisposition.pop;
    return await super.willPop();
  }

  @override
  bool didPop(T result) {
    if (_localHistory != null && _localHistory.isNotEmpty) {
      final LocalHistoryEntry entry = _localHistory.removeLast();
      assert(entry._owner == this);
      entry._owner = null;
      entry._notifyRemoved();
      if (_localHistory.isEmpty)
        changedInternalState();
      return false;
    }
    return super.didPop(result);
  }

  @override
  bool get willHandlePopInternally {
    return _localHistory != null && _localHistory.isNotEmpty;
  }

  /// Called whenever the internal state of the route has changed.
  ///
  /// This should be called whenever [willHandlePopInternally] and [didPop]
  /// might change the value they return. It is used by [ModalRoute], for
  /// example, to report the new information via its inherited widget to any
  /// children of the route.
  @protected
  @mustCallSuper
  void changedInternalState() { }
}

class _ModalScopeStatus extends InheritedWidget {
  const _ModalScopeStatus({
    Key key,
    @required this.isCurrent,
    @required this.canPop,
    @required this.route,
    @required Widget child
  }) : assert(isCurrent != null),
       assert(canPop != null),
       assert(route != null),
       assert(child != null),
       super(key: key, child: child);

  final bool isCurrent;
  final bool canPop;
  final Route<dynamic> route;

  @override
  bool updateShouldNotify(_ModalScopeStatus old) {
    return isCurrent != old.isCurrent ||
           canPop != old.canPop ||
           route != old.route;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder description) {
    super.debugFillProperties(description);
    description.add(new FlagProperty('isCurrent', value: isCurrent, ifTrue: 'active', ifFalse: 'inactive'));
    description.add(new FlagProperty('canPop', value: canPop, ifTrue: 'can pop'));
  }
}

class _ModalScope extends StatefulWidget {
  const _ModalScope({
    Key key,
    this.route,
    @required this.page,
  }) : super(key: key);

  final ModalRoute<dynamic> route;
  final Widget page;

  @override
  _ModalScopeState createState() => new _ModalScopeState();
}

class _ModalScopeState extends State<_ModalScope> {
  // See addScopedWillPopCallback, removeScopedWillPopCallback in ModalRoute.
  final List<WillPopCallback> _willPopCallbacks = <WillPopCallback>[];

  @override
  void initState() {
    super.initState();
    widget.route.animation?.addStatusListener(_animationStatusChanged);
    widget.route.secondaryAnimation?.addStatusListener(_animationStatusChanged);
  }

  @override
  void didUpdateWidget(_ModalScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(widget.route == oldWidget.route);
  }

  @override
  void dispose() {
    widget.route.animation?.removeStatusListener(_animationStatusChanged);
    widget.route.secondaryAnimation?.removeStatusListener(_animationStatusChanged);
    super.dispose();
  }

  void addWillPopCallback(WillPopCallback callback) {
    assert(mounted);
    _willPopCallbacks.add(callback);
  }

  void removeWillPopCallback(WillPopCallback callback) {
    assert(mounted);
    _willPopCallbacks.remove(callback);
  }

  void _animationStatusChanged(AnimationStatus status) {
    setState(() {
      // The animation's states are our build state, and they changed already.
    });
  }

  void _routeSetState(VoidCallback fn) {
    setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    return new FocusScope(
      node: widget.route.focusScopeNode,
      child: new Offstage(
        offstage: widget.route.offstage,
        child: new IgnorePointer(
          ignoring: widget.route.animation?.status == AnimationStatus.reverse,
          child: widget.route.buildTransitions(
            context,
            widget.route.animation,
            widget.route.secondaryAnimation,
            new RepaintBoundary(
              child: new PageStorage(
                key: widget.route._subtreeKey,
                bucket: widget.route._storageBucket,
                child: new _ModalScopeStatus(
                  route: widget.route,
                  isCurrent: widget.route.isCurrent,
                  canPop: widget.route.canPop,
                  child: widget.page,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A route that blocks interaction with previous routes.
///
/// ModalRoutes cover the entire [Navigator]. They are not necessarily [opaque],
/// however; for example, a pop-up menu uses a ModalRoute but only shows the menu
/// in a small box overlapping the previous route.
abstract class ModalRoute<T> extends TransitionRoute<T> with LocalHistoryRoute<T> {
  /// Creates a route that blocks interaction with previous routes.
  ModalRoute({
    this.settings: const RouteSettings()
  });

  // The API for general users of this class

  /// The settings for this route.
  ///
  /// See [RouteSettings] for details.
  final RouteSettings settings;

  /// Returns the modal route most closely associated with the given context.
  ///
  /// Returns null if the given context is not associated with a modal route.
  ///
  /// Typical usage is as follows:
  ///
  /// ```dart
  /// ModalRoute<dynamic> route = ModalRoute.of(context);
  /// ```
  ///
  /// The given [BuildContext] will be rebuilt if the state of the route changes
  /// (specifically, if [isCurrent] or [canPop] change value).
  static ModalRoute<dynamic> of(BuildContext context) {
    final _ModalScopeStatus widget = context.inheritFromWidgetOfExactType(_ModalScopeStatus);
    return widget?.route;
  }

  /// Schedule a call to [buildTransitions].
  ///
  /// Whenever you need to change internal state for a ModalRoute object, make
  /// the change in a function that you pass to [setState], as in:
  ///
  /// ```dart
  /// setState(() { myState = newValue });
  /// ```
  ///
  /// If you just change the state directly without calling [setState], then the
  /// route will not be scheduled for rebuilding, meaning that its rendering
  /// will not be updated.
  @protected
  void setState(VoidCallback fn) {
    if (_scopeKey.currentState != null) {
      _scopeKey.currentState._routeSetState(fn);
    } else {
      // The route isn't currently visible, so we don't have to call its setState
      // method, but we do still need to call the fn callback, otherwise the state
      // in the route won't be updated!
      fn();
    }
  }

  /// Returns a predicate that's true if the route has the specified name and if
  /// popping the route will not yield the same route, i.e. if the route's
  /// [willHandlePopInternally] property is false.
  ///
  /// This function is typically used with [Navigator.popUntil()].
  static RoutePredicate withName(String name) {
    return (Route<dynamic> route) {
      return !route.willHandlePopInternally
          && route is ModalRoute
          && route.settings.name == name;
    };
  }

  // The API for subclasses to override - used by _ModalScope

  /// Override this method to build the primary content of this route.
  ///
  /// The arguments have the following meanings:
  ///
  ///  * `context`: The context in which the route is being built.
  ///  * [animation]: The animation for this route's transition. When entering,
  ///    the animation runs forward from 0.0 to 1.0. When exiting, this animation
  ///    runs backwards from 1.0 to 0.0.
  ///  * [secondaryAnimation]: The animation for the route being pushed on top of
  ///    this route. This animation lets this route coordinate with the entrance
  ///    and exit transition of routes pushed on top of this route.
  ///
  /// This method is called when the route is first built, and rarely
  /// thereafter. In particular, it is not called again when the route's state
  /// changes. For a builder that is called every time the route's state
  /// changes, consider [buildTransitions]. For widgets that change their
  /// behavior when the route's state changes, consider [ModalRoute.of] to
  /// obtain a reference to the route; this will cause the widget to be rebuilt
  /// each time the route changes state.
  ///
  /// In general, [buildPage] should be used to build the page contents, and
  /// [buildTransitions] for the widgets that change as the page is brought in
  /// and out of view. Avoid using [buildTransitions] for content that never
  /// changes; building such content once from [buildPage] is more efficient.
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation);

  /// Override this method to wrap the [child] with one or more transition
  /// widgets that define how the route arrives on and leaves the screen.
  ///
  /// By default, the child (which contains the widget returned by [buildPage])
  /// is not wrapped in any transition widgets.
  ///
  /// The [buildTransitions] method, in contrast to [buildPage], is called each
  /// time the [Route]'s state changes (e.g. the value of [canPop]).
  ///
  /// The [buildTransitions] method is typically used to define transitions
  /// that animate the new topmost route's comings and goings. When the
  /// [Navigator] pushes a route on the top of its stack, the new route's
  /// primary [animation] runs from 0.0 to 1.0. When the Navigator pops the
  /// topmost route, e.g. because the use pressed the back button, the
  /// primary animation runs from 1.0 to 0.0.
  ///
  /// The following example uses the primary animation to drive a
  /// [SlideTransition] that translates the top of the new route vertically
  /// from the bottom of the screen when it is pushed on the Navigator's
  /// stack. When the route is popped the SlideTransition translates the
  /// route from the top of the screen back to the bottom.
  ///
  /// ```dart
  /// new PageRouteBuilder(
  ///   pageBuilder: (BuildContext context,
  ///       Animation<double> animation,
  ///       Animation<double> secondaryAnimation,
  ///       Widget child,
  ///   ) {
  ///     return new Scaffold(
  ///       appBar: new AppBar(title: new Text('Hello')),
  ///       body: new Center(
  ///         child: new Text('Hello World'),
  ///       ),
  ///     );
  ///   },
  ///   transitionsBuilder: (
  ///       BuildContext context,
  ///       Animation<double> animation,
  ///       Animation<double> secondaryAnimation,
  ///       Widget child,
  ///    ) {
  ///     return new SlideTransition(
  ///       position: new Tween<Offset>(
  ///         begin: const Offset(0.0, 1.0),
  ///         end: Offset.zero,
  ///       ).animate(animation),
  ///       child: child, // child is the value returned by pageBuilder
  ///     );
  ///   },
  /// );
  ///```
  ///
  /// We've used [PageRouteBuilder] to demonstrate the [buildTransitions] method
  /// here. The body of an override of the [buildTransitions] method would be
  /// defined in the same way.
  ///
  /// When the [Navigator] pushes a route on the top of its stack, the
  /// [secondaryAnimation] can be used to define how the route that was on
  /// the top of the stack leaves the screen. Similarly when the topmost route
  /// is popped, the secondaryAnimation can be used to define how the route
  /// below it reappears on the screen. When the Navigator pushes a new route
  /// on the top of its stack, the old topmost route's secondaryAnimation
  /// runs from 0.0 to 1.0.  When the Navigator pops the topmost route, the
  /// secondaryAnimation for the route below it runs from 1.0 to 0.0.
  ///
  /// The example below adds a transition that's driven by the
  /// [secondaryAnimation]. When this route disappears because a new route has
  /// been pushed on top of it, it translates in the opposite direction of
  /// the new route. Likewise when the route is exposed because the topmost
  /// route has been popped off.
  ///
  /// ```dart
  ///   transitionsBuilder: (
  ///       BuildContext context,
  ///       Animation<double> animation,
  ///       Animation<double> secondaryAnimation,
  ///       Widget child,
  ///   ) {
  ///     return new SlideTransition(
  ///       position: new AlignmentTween(
  ///         begin: const Offset(0.0, 1.0),
  ///         end: Offset.zero,
  ///       ).animate(animation),
  ///       child: new SlideTransition(
  ///         position: new TweenOffset(
  ///           begin: Offset.zero,
  ///           end: const Offset(0.0, 1.0),
  ///         ).animate(secondaryAnimation),
  ///         child: child,
  ///       ),
  ///     );
  ///   }
  /// ```
  ///
  /// In practice the `secondaryAnimation` is used pretty rarely.
  ///
  /// The arguments to this method are as follows:
  ///
  ///  * `context`: The context in which the route is being built.
  ///  * [animation]: When the [Navigator] pushes a route on the top of its stack,
  ///    the new route's primary [animation] runs from 0.0 to 1.0. When the [Navigator]
  ///    pops the topmost route this animation runs from 1.0 to 0.0.
  ///  * [secondaryAnimation]: When the Navigator pushes a new route
  ///    on the top of its stack, the old topmost route's [secondaryAnimation]
  ///    runs from 0.0 to 1.0.  When the [Navigator] pops the topmost route, the
  ///    [secondaryAnimation] for the route below it runs from 1.0 to 0.0.
  ///  * `child`, the page contents.
  ///
  /// See also:
  ///
  ///  * [buildPage], which is used to describe the actual contents of the page,
  ///    and whose result is passed to the `child` argument of this method.
  Widget buildTransitions(
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
  ) {
    return child;
  }

  /// The node this route will use for its root [FocusScope] widget.
  final FocusScopeNode focusScopeNode = new FocusScopeNode();

  @override
  void install(OverlayEntry insertionPoint) {
    super.install(insertionPoint);
    _animationProxy = new ProxyAnimation(super.animation);
    _secondaryAnimationProxy = new ProxyAnimation(super.secondaryAnimation);
  }

  @override
  TickerFuture didPush() {
    navigator.focusScopeNode.setFirstFocus(focusScopeNode);
    return super.didPush();
  }

  @override
  void dispose() {
    focusScopeNode.detach();
    super.dispose();
  }

  // The API for subclasses to override - used by this class

  /// Whether you can dismiss this route by tapping the modal barrier.
  ///
  /// The modal barrier is the scrim that is rendered behind each route, which
  /// generally prevents the user from interacting with the route below the
  /// current route, and normally partially obscures such routes.
  ///
  /// For example, when a dialog is on the screen, the page below the dialog is
  /// usually darkened by the modal barrier.
  ///
  /// If [barrierDismissible] is true, then tapping this barrier will cause the
  /// current route to be popped (see [Navigator.pop]) with null as the value.
  ///
  /// If [barrierDismissible] is false, then tapping the barrier has no effect.
  ///
  /// See also:
  ///
  ///  * [barrierColor], which controls the color of the scrim for this route.
  ///  * [ModalBarrier], the widget that implements this feature.
  bool get barrierDismissible;

  /// The color to use for the modal barrier. If this is null, the barrier will
  /// be transparent.
  ///
  /// The modal barrier is the scrim that is rendered behind each route, which
  /// generally prevents the user from interacting with the route below the
  /// current route, and normally partially obscures such routes.
  ///
  /// For example, when a dialog is on the screen, the page below the dialog is
  /// usually darkened by the modal barrier.
  ///
  /// The color is ignored, and the barrier made invisible, when [offstage] is
  /// true.
  ///
  /// While the route is animating into position, the color is animated from
  /// transparent to the specified color.
  ///
  /// See also:
  ///
  ///  * [barrierDismissible], which controls the behavior of the barrier when
  ///    tapped.
  ///  * [ModalBarrier], the widget that implements this feature.
  Color get barrierColor;

  /// Whether the route should remain in memory when it is inactive. If this is
  /// true, then the route is maintained, so that any futures it is holding from
  /// the next route will properly resolve when the next route pops. If this is
  /// not necessary, this can be set to false to allow the framework to entirely
  /// discard the route's widget hierarchy when it is not visible.
  bool get maintainState;


  // The API for _ModalScope and HeroController

  /// Whether this route is currently offstage.
  ///
  /// On the first frame of a route's entrance transition, the route is built
  /// [Offstage] using an animation progress of 1.0. The route is invisible and
  /// non-interactive, but each widget has its final size and position. This
  /// mechanism lets the [HeroController] determine the final local of any hero
  /// widgets being animated as part of the transition.
  ///
  /// The modal barrier, if any, is not rendered if [offstage] is true (see
  /// [barrierColor]).
  bool get offstage => _offstage;
  bool _offstage = false;
  set offstage(bool value) {
    if (_offstage == value)
      return;
    setState(() {
      _offstage = value;
    });
    _animationProxy.parent = _offstage ? kAlwaysCompleteAnimation : super.animation;
    _secondaryAnimationProxy.parent = _offstage ? kAlwaysDismissedAnimation : super.secondaryAnimation;
  }

  /// The build context for the subtree containing the primary content of this route.
  BuildContext get subtreeContext => _subtreeKey.currentContext;

  @override
  Animation<double> get animation => _animationProxy;
  ProxyAnimation _animationProxy;

  @override
  Animation<double> get secondaryAnimation => _secondaryAnimationProxy;
  ProxyAnimation _secondaryAnimationProxy;

  /// Returns the value of the first callback added with
  /// [addScopedWillPopCallback] that returns false. If they all return true,
  /// returns the inherited method's result (see [Route.willPop]).
  ///
  /// Typically this method is not overridden because applications usually
  /// don't create modal routes directly, they use higher level primitives
  /// like [showDialog]. The scoped [WillPopCallback] list makes it possible
  /// for ModalRoute descendants to collectively define the value of `willPop`.
  ///
  /// See also:
  ///
  /// * [Form], which provides an `onWillPop` callback that uses this mechanism.
  /// * [addScopedWillPopCallback], which adds a callback to the list this
  ///   method checks.
  /// * [removeScopedWillPopCallback], which removes a callback from the list
  ///   this method checks.
  @override
  Future<RoutePopDisposition> willPop() async {
    final _ModalScopeState scope = _scopeKey.currentState;
    assert(scope != null);
    for (WillPopCallback callback in new List<WillPopCallback>.from(scope._willPopCallbacks)) {
      if (!await callback())
        return RoutePopDisposition.doNotPop;
    }
    return await super.willPop();
  }

  /// Enables this route to veto attempts by the user to dismiss it.
  ///
  /// This callback is typically added using a [WillPopScope] widget. That
  /// widget finds the enclosing [ModalRoute] and uses this function to register
  /// this callback:
  ///
  /// ```dart
  /// Widget build(BuildContext context) {
  ///   return new WillPopScope(
  ///     onWillPop: askTheUserIfTheyAreSure,
  ///     child: ...,
  ///   );
  /// }
  /// ```
  ///
  /// This callback runs asynchronously and it's possible that it will be called
  /// after its route has been disposed. The callback should check [State.mounted]
  /// before doing anything.
  ///
  /// A typical application of this callback would be to warn the user about
  /// unsaved [Form] data if the user attempts to back out of the form. In that
  /// case, use the [Form.onWillPop] property to register the callback.
  ///
  /// To register a callback manually, look up the enclosing [ModalRoute] in a
  /// [State.didChangeDependencies] callback:
  ///
  /// ```dart
  /// ModalRoute<dynamic> _route;
  ///
  /// @override
  /// void didChangeDependencies() {
  ///  super.didChangeDependencies();
  ///  _route?.removeScopedWillPopCallback(askTheUserIfTheyAreSure);
  ///  _route = ModalRoute.of(context);
  ///  _route?.addScopedWillPopCallback(askTheUserIfTheyAreSure);
  /// }
  /// ```
  ///
  /// If you register a callback manually, be sure to remove the callback with
  /// [removeScopedWillPopCallback] by the time the widget has been disposed. A
  /// stateful widget can do this in its dispose method (continuing the previous
  /// example):
  ///
  /// ```dart
  /// @override
  /// void dispose() {
  ///   _route?.removeScopedWillPopCallback(askTheUserIfTheyAreSure);
  ///   _route = null;
  ///   super.dispose();
  /// }
  /// ```
  ///
  /// See also:
  ///
  ///  * [WillPopScope], which manages the registration and unregistration
  ///    process automatically.
  ///  * [Form], which provides an `onWillPop` callback that uses this mechanism.
  ///  * [willPop], which runs the callbacks added with this method.
  ///  * [removeScopedWillPopCallback], which removes a callback from the list
  ///    that [willPop] checks.
  void addScopedWillPopCallback(WillPopCallback callback) {
    assert(_scopeKey.currentState != null);
    _scopeKey.currentState.addWillPopCallback(callback);
  }

  /// Remove one of the callbacks run by [willPop].
  ///
  /// See also:
  ///
  ///  * [Form], which provides an `onWillPop` callback that uses this mechanism.
  ///  * [addScopedWillPopCallback], which adds callback to the list
  ///    checked by [willPop].
  void removeScopedWillPopCallback(WillPopCallback callback) {
    assert(_scopeKey.currentState != null);
    _scopeKey.currentState.removeWillPopCallback(callback);
  }

  /// True if one or more [WillPopCallback] callbacks exist.
  ///
  /// This method is used to disable the horizontal swipe pop gesture
  /// supported by [MaterialPageRoute] for [TargetPlatform.iOS].
  /// If a pop might be vetoed, then the back gesture is disabled.
  ///
  /// The [buildTransitions] method will not be called again if this changes,
  /// since it can change during the build as descendants of the route add or
  /// remove callbacks.
  ///
  /// See also:
  ///
  ///  * [addScopedWillPopCallback], which adds a callback.
  ///  * [removeScopedWillPopCallback], which removes a callback.
  ///  * [willHandlePopInternally], which reports on another reason why
  ///    a pop might be vetoed.
  @protected
  bool get hasScopedWillPopCallback {
    return _scopeKey.currentState == null || _scopeKey.currentState._willPopCallbacks.isNotEmpty;
  }

  @override
  void changedInternalState() {
    super.changedInternalState();
    setState(() { /* internal state already changed */ });
  }

  @override
  void didChangePrevious(Route<dynamic> route) {
    super.didChangePrevious(route);
    setState(() { /* this might affect canPop */ });
  }

  /// Whether this route can be popped.
  ///
  /// When this changes, the route will rebuild, and any widgets that used
  /// [ModalRoute.of] will be notified.
  bool get canPop => !isFirst || willHandlePopInternally;

  // Internals

  final GlobalKey<_ModalScopeState> _scopeKey = new GlobalKey<_ModalScopeState>();
  final GlobalKey _subtreeKey = new GlobalKey();
  final PageStorageBucket _storageBucket = new PageStorageBucket();

  // one of the builders
  Widget _buildModalBarrier(BuildContext context) {
    Widget barrier;
    if (barrierColor != null && !offstage) {
      assert(barrierColor != _kTransparent);
      final Animation<Color> color = new ColorTween(
        begin: _kTransparent,
        end: barrierColor
      ).animate(new CurvedAnimation(
        parent: animation,
        curve: Curves.ease
      ));
      barrier = new AnimatedModalBarrier(
        color: color,
        dismissible: barrierDismissible
      );
    } else {
      barrier = new ModalBarrier(dismissible: barrierDismissible);
    }
    assert(animation.status != AnimationStatus.dismissed);
    return new IgnorePointer(
      ignoring: animation.status == AnimationStatus.reverse,
      child: barrier
    );
  }

  // one of the builders
  Widget _buildModalScope(BuildContext context) {
    return new _ModalScope(
      key: _scopeKey,
      route: this,
      page: buildPage(context, animation, secondaryAnimation)
      // _ModalScope calls buildTransitions(), defined above
    );
  }

  @override
  Iterable<OverlayEntry> createOverlayEntries() sync* {
    yield new OverlayEntry(builder: _buildModalBarrier);
    yield new OverlayEntry(builder: _buildModalScope, maintainState: maintainState);
  }

  @override
  String toString() => '$runtimeType($settings, animation: $_animation)';
}

/// A modal route that overlays a widget over the current route.
abstract class PopupRoute<T> extends ModalRoute<T> {
  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  void didChangeNext(Route<dynamic> nextRoute) {
    assert(nextRoute is! PageRoute<dynamic>);
    super.didChangeNext(nextRoute);
  }
}

/// A [Navigator] observer that notifies [RouteAware]s of changes to the
/// state of their [Route].
///
/// [RouteObserver] informs subscribers whenever a route of type `T` is pushed
/// on top of their own route of type `T` or popped from it. This is for example
/// useful to keep track of page transitions, e.i. a `RouteObserver<PageRoute>`
/// will inform subscribed [RouteAware]s whenever the user navigates away from
/// the current page route to another page route.
///
/// If you want to be informed about route changes of any type, you should
/// instantiate a `RouteObserver<Route>`.
///
/// ## Sample code
///
/// To make a [StatefulWidget] aware of its current [Route] state, implement
/// [RouteAware] in its [State] and subscribe it to a [RouteObserver]:
///
/// ```dart
/// // Register the RouteObserver as a navigation observer.
/// final RouteObserver<PageRoute> routeObserver = new RouteObserver<PageRoute>();
/// void main() {
///   runApp(new MaterialApp(
///     home: new Container(),
///     navigatorObservers: [routeObserver],
///   ));
/// }
///
/// class RouteAwareWidget extends StatefulWidget {
///   State<RouteAwareWidget> createState() => new RouteAwareWidgetState();
/// }
///
/// // Implement RouteAware in a widget's state and subscribe it to the RouteObserver.
/// class RouteAwareWidgetState extends State<RouteAwareWidget> with RouteAware {
///
///   @override
///   void didChangeDependencies() {
///     super.didChangeDependencies();
///     routeObserver.subscribe(this, ModalRoute.of(context));
///   }
///
///   @override
///   void dispose() {
///     routeObserver.unsubscribe(this);
///     super.dispose();
///   }
///
///   @override
///   void didPush() {
///     // Route was pushed onto navigator and is now topmost route.
///   }
///
///   @override
///   void didPopNext() {
///     // Covering route was popped off the navigator.
///   }
///
///   @override
///   Widget build(BuildContext context) => new Container();
///
/// }
///
/// ```
class RouteObserver<T extends Route<dynamic>> extends NavigatorObserver {
  final Map<T, RouteAware> _listeners = <T, RouteAware>{};

  /// Subscribe [routeAware] to be informed about changes to [route].
  ///
  /// Going forward, [routeAware] will be informed about qualifying changes
  /// to [route], e.g. when [route] is covered by another route or when [route]
  /// is popped off the [Navigator] stack.
  void subscribe(RouteAware routeAware, T route) {
    assert(routeAware != null);
    assert(route != null);
    if (!_listeners.containsKey(route)) {
      routeAware.didPush();
      _listeners[route] = routeAware;
    }
  }

  /// Unsubscribe [routeAware].
  ///
  /// [routeAware] is no longer informed about changes to its route.
  void unsubscribe(RouteAware routeAware) {
    assert(routeAware != null);
    _listeners.remove(routeAware);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic> previousRoute) {
    if (route is T && previousRoute is T) {
      _listeners[previousRoute]?.didPopNext();
      _listeners[route]?.didPop();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic> previousRoute) {
    if (route is T && previousRoute is T) {
      _listeners[previousRoute]?.didPushNext();
    }
  }
}

/// A interface that is aware of its current Route.
abstract class RouteAware {
  /// Called when the top route has been popped off, and the current route
  /// shows up.
  void didPopNext() { }

  /// Called when the current route has been pushed.
  void didPush() { }

  /// Called when the current route has been popped off.
  void didPop() { }

  /// Called when a new route has been pushed, and the current route is no
  /// longer visible.
  void didPushNext() { }
}
