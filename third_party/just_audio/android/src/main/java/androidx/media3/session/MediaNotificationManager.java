/*
 * Copyright 2022 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License
 */
package androidx.media3.session;

import static android.app.Service.STOP_FOREGROUND_DETACH;
import static android.app.Service.STOP_FOREGROUND_REMOVE;
import static java.util.concurrent.TimeUnit.MILLISECONDS;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.DoNotInline;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.core.app.NotificationManagerCompat;
import androidx.core.content.ContextCompat;
import androidx.media3.common.Player;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.Util;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeoutException;

/**
 * Manages media notifications for a {@link MediaSessionService} and sets the service as
 * foreground/background according to the player state.
 *
 * <p>All methods must be called on the main thread.
 */
/* package */ final class MediaNotificationManager {

  private static final String TAG = "MediaNtfMng";

  private final MediaSessionService mediaSessionService;
  private final MediaNotification.Provider mediaNotificationProvider;
  private final MediaNotification.ActionFactory actionFactory;
  private final NotificationManagerCompat notificationManagerCompat;
  private final Executor mainExecutor;
  private final Intent startSelfIntent;
  private final Map<MediaSession, ListenableFuture<MediaController>> controllerMap;

  private int totalNotificationCount;
  @Nullable private MediaNotification mediaNotification;
  private boolean startedInForeground;

  public MediaNotificationManager(
      MediaSessionService mediaSessionService,
      MediaNotification.Provider mediaNotificationProvider,
      MediaNotification.ActionFactory actionFactory) {
    this.mediaSessionService = mediaSessionService;
    this.mediaNotificationProvider = mediaNotificationProvider;
    this.actionFactory = actionFactory;
    notificationManagerCompat = NotificationManagerCompat.from(mediaSessionService);
    Handler mainHandler = new Handler(Looper.getMainLooper());
    mainExecutor = (runnable) -> Util.postOrRun(mainHandler, runnable);
    startSelfIntent = new Intent(mediaSessionService, mediaSessionService.getClass());
    controllerMap = new HashMap<>();
    startedInForeground = false;
  }

  public void addSession(MediaSession session) {
    if (controllerMap.containsKey(session)) {
      return;
    }
    MediaControllerListener listener = new MediaControllerListener(mediaSessionService, session);
    Bundle connectionHints = new Bundle();
    connectionHints.putBoolean(MediaController.KEY_MEDIA_NOTIFICATION_CONTROLLER_FLAG, true);
    ListenableFuture<MediaController> controllerFuture =
        new MediaController.Builder(mediaSessionService, session.getToken())
            .setConnectionHints(connectionHints)
            .setListener(listener)
            .setApplicationLooper(Looper.getMainLooper())
            .buildAsync();
    controllerMap.put(session, controllerFuture);
    controllerFuture.addListener(
        () -> {
          try {
            MediaController controller = controllerFuture.get(/* time= */ 0, MILLISECONDS);
            listener.onConnected(shouldShowNotification(session));
            controller.addListener(listener);
          } catch (CancellationException
              | ExecutionException
              | InterruptedException
              | TimeoutException e) {
            // MediaSession or MediaController is released too early. Stop monitoring the session.
            mediaSessionService.removeSession(session);
          }
        },
        mainExecutor);
  }

  public void removeSession(MediaSession session) {
    @Nullable ListenableFuture<MediaController> future = controllerMap.remove(session);
    if (future != null) {
      MediaController.releaseFuture(future);
    }
  }

  public void onCustomAction(MediaSession session, String action, Bundle extras) {
    @Nullable MediaController mediaController = getConnectedControllerForSession(session);
    if (mediaController == null) {
      return;
    }
    // Let the notification provider handle the command first before forwarding it directly.
    Util.postOrRun(
        new Handler(session.getPlayer().getApplicationLooper()),
        () -> {
          if (!mediaNotificationProvider.handleCustomCommand(session, action, extras)) {
            mainExecutor.execute(
                () -> sendCustomCommandIfCommandIsAvailable(mediaController, action, extras));
          }
        });
  }

  /**
   * Updates the notification.
   *
   * @param session A session that needs notification update.
   * @param startInForegroundRequired Whether the service is required to start in the foreground.
   */
  public void updateNotification(MediaSession session, boolean startInForegroundRequired) {
    if (!mediaSessionService.isSessionAdded(session) || !shouldShowNotification(session)) {
      // MD3Music fork（批次15·P0）：切歌/跨 fade 时 STATE_IDLE 是过渡常态，
      // shouldShowNotification 会短暂为 false。此处只允许 DETACH（不删除通知），
      // 否则通知被移除后需重新 startForeground，而 Android 12 后台会拒绝，
      // 通知永久消失且进程失去前台载体。真实停止（playWhenReady=false）仍由
      // maybeStopForegroundService 内部的 shouldRunInForeground 判定后撤除。
      maybeStopForegroundService(/* removeNotifications= */ false);
      return;
    }

    int notificationSequence = ++totalNotificationCount;
    MediaController mediaNotificationController = null;
    ListenableFuture<MediaController> controller = controllerMap.get(session);
    if (controller != null && controller.isDone()) {
      try {
        mediaNotificationController = Futures.getDone(controller);
      } catch (ExecutionException e) {
        // Ignore.
      }
    }
    ImmutableList<CommandButton> customLayout =
        mediaNotificationController != null
            ? mediaNotificationController.getCustomLayout()
            : ImmutableList.of();
    MediaNotification.Provider.Callback callback =
        notification ->
            mainExecutor.execute(
                () -> onNotificationUpdated(notificationSequence, session, notification));
    Util.postOrRun(
        new Handler(session.getPlayer().getApplicationLooper()),
        () -> {
          MediaNotification mediaNotification =
              this.mediaNotificationProvider.createNotification(
                  session, customLayout, actionFactory, callback);
          mainExecutor.execute(
              () ->
                  updateNotificationInternal(
                      session, mediaNotification, startInForegroundRequired));
        });
  }

  public boolean isStartedInForeground() {
    return startedInForeground;
  }

  /* package */ boolean shouldRunInForeground(
      MediaSession session, boolean startInForegroundWhenPaused) {
    @Nullable MediaController controller = getConnectedControllerForSession(session);
    // MD3Music fork（批次15·P0）：不再要求 STATE_READY/BUFFERING。
    // 本工程自维护播放队列并做跨 fade 切歌，切歌瞬间播放器会短暂进入
    // STATE_IDLE——这是过渡态而非停止播放。若此时判定「不需前台」，会执行
    // stopForeground 掉前台；而 Android 12 起应用在后台既不能 startForegroundService
    // 也不能 startForeground（ForegroundServiceStartNotAllowedException），
    // 该窗口一旦掉前台就永久无法恢复，进程随后被冻结/回收 → 播放中止。
    // 因此只以播放意愿（playWhenReady）为准：只要用户仍希望播放就保持前台。
    return controller != null
        && (controller.getPlayWhenReady() || startInForegroundWhenPaused);
  }

  private void onNotificationUpdated(
      int notificationSequence, MediaSession session, MediaNotification mediaNotification) {
    if (notificationSequence == totalNotificationCount) {
      boolean startInForegroundRequired =
          shouldRunInForeground(session, /* startInForegroundWhenPaused= */ false);
      updateNotificationInternal(session, mediaNotification, startInForegroundRequired);
    }
  }

  // POST_NOTIFICATIONS permission is not required for media session related notifications.
  // https://developer.android.com/develop/ui/views/notifications/notification-permission#exemptions-media-sessions
  @SuppressLint("MissingPermission")
  private void updateNotificationInternal(
      MediaSession session,
      MediaNotification mediaNotification,
      boolean startInForegroundRequired) {
    if (Util.SDK_INT >= 21) {
      // Call Notification.MediaStyle#setMediaSession() indirectly.
      android.media.session.MediaSession.Token fwkToken =
          (android.media.session.MediaSession.Token)
              session.getSessionCompat().getSessionToken().getToken();
      mediaNotification.notification.extras.putParcelable(
          Notification.EXTRA_MEDIA_SESSION, fwkToken);
    }
    this.mediaNotification = mediaNotification;
    if (startInForegroundRequired) {
      startForeground(mediaNotification);
    } else {
      // Notification manager has to be updated first to avoid missing updates
      // (https://github.com/androidx/media/issues/192).
      notificationManagerCompat.notify(
          mediaNotification.notificationId, mediaNotification.notification);
      maybeStopForegroundService(/* removeNotifications= */ false);
    }
  }

  /**
   * Stops the service from the foreground, if no player is actively playing content.
   *
   * @param removeNotifications Whether to remove notifications, if the service is stopped from the
   *     foreground.
   */
  private void maybeStopForegroundService(boolean removeNotifications) {
    List<MediaSession> sessions = mediaSessionService.getSessions();
    for (int i = 0; i < sessions.size(); i++) {
      if (shouldRunInForeground(sessions.get(i), /* startInForegroundWhenPaused= */ false)) {
        return;
      }
    }
    stopForeground(removeNotifications);
    if (removeNotifications && mediaNotification != null) {
      notificationManagerCompat.cancel(mediaNotification.notificationId);
      // Update the notification count so that if a pending notification callback arrives (e.g., a
      // bitmap is loaded), we don't show the notification.
      totalNotificationCount++;
      mediaNotification = null;
    }
  }

  private boolean shouldShowNotification(MediaSession session) {
    MediaController controller = getConnectedControllerForSession(session);
    return controller != null
        && !controller.getCurrentTimeline().isEmpty()
        && controller.getPlaybackState() != Player.STATE_IDLE;
  }

  @Nullable
  private MediaController getConnectedControllerForSession(MediaSession session) {
    ListenableFuture<MediaController> controller = controllerMap.get(session);
    if (controller == null || !controller.isDone()) {
      return null;
    }
    try {
      return Futures.getDone(controller);
    } catch (ExecutionException exception) {
      // We should never reach this.
      throw new IllegalStateException(exception);
    }
  }

  private void sendCustomCommandIfCommandIsAvailable(
      MediaController mediaController, String action, Bundle extras) {
    @Nullable SessionCommand customCommand = null;
    for (SessionCommand command : mediaController.getAvailableSessionCommands().commands) {
      if (command.commandCode == SessionCommand.COMMAND_CODE_CUSTOM
          && command.customAction.equals(action)) {
        customCommand = command;
        break;
      }
    }
    if (customCommand != null
        && mediaController.getAvailableSessionCommands().contains(customCommand)) {
      ListenableFuture<SessionResult> future =
          mediaController.sendCustomCommand(
              new SessionCommand(action, extras), /* args= */ Bundle.EMPTY);
      Futures.addCallback(
          future,
          new FutureCallback<SessionResult>() {
            @Override
            public void onSuccess(SessionResult result) {
              // Do nothing.
            }

            @Override
            public void onFailure(Throwable t) {
              Log.w(TAG, "custom command " + action + " produced an error: " + t.getMessage(), t);
            }
          },
          MoreExecutors.directExecutor());
    }
  }

  private static final class MediaControllerListener
      implements MediaController.Listener, Player.Listener {
    private final MediaSessionService mediaSessionService;
    private final MediaSession session;

    public MediaControllerListener(MediaSessionService mediaSessionService, MediaSession session) {
      this.mediaSessionService = mediaSessionService;
      this.session = session;
    }

    public void onConnected(boolean shouldShowNotification) {
      if (shouldShowNotification) {
        mediaSessionService.onUpdateNotificationInternal(
            session, /* startInForegroundWhenPaused= */ false);
      }
    }

    @Override
    public void onCustomLayoutChanged(MediaController controller, List<CommandButton> layout) {
      mediaSessionService.onUpdateNotificationInternal(
          session, /* startInForegroundWhenPaused= */ false);
    }

    @Override
    public void onAvailableSessionCommandsChanged(
        MediaController controller, SessionCommands commands) {
      mediaSessionService.onUpdateNotificationInternal(
          session, /* startInForegroundWhenPaused= */ false);
    }

    @Override
    public void onDisconnected(MediaController controller) {
      if (mediaSessionService.isSessionAdded(session)) {
        mediaSessionService.removeSession(session);
      }
      // We may need to hide the notification.
      mediaSessionService.onUpdateNotificationInternal(
          session, /* startInForegroundWhenPaused= */ false);
    }

    @Override
    public void onEvents(Player player, Player.Events events) {
      // We must limit the frequency of notification updates, otherwise the system may suppress
      // them.
      if (events.containsAny(
          Player.EVENT_PLAYBACK_STATE_CHANGED,
          Player.EVENT_PLAY_WHEN_READY_CHANGED,
          Player.EVENT_MEDIA_METADATA_CHANGED,
          Player.EVENT_TIMELINE_CHANGED)) {
        mediaSessionService.onUpdateNotificationInternal(
            session, /* startInForegroundWhenPaused= */ false);
      }
    }
  }

  @SuppressLint("InlinedApi") // Using compile time constant FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
  private void startForeground(MediaNotification mediaNotification) {
    try {
      ContextCompat.startForegroundService(mediaSessionService, startSelfIntent);
    } catch (Throwable e) {
      // MD3Music fork：后台切歌/跨fade 时 startForegroundService 被系统拒绝
      // （ForegroundServiceStartNotAllowedException，mAllowStartForeground=false）。
      // 若就此中止，通知内容（封面/标题）在后台永远无法刷新，媒体卡片停在旧歌。
      // 批次14：本服务已被 AudioPlaybackService 以 BIND_AUTO_CREATE 绑定而处于
      // 运行态——对「已运行」的服务直接 startForeground 不走后台启动限制。
      // 先尝试直接置前台：成功则本服务成为进程的 FGS 载体（杜绝保活撤除后
      // 零 FGS 被系统杀）；直接置前台也失败（极端场景）才降级为纯 notify()
      // 仅刷新通知内容，进程保活交回 AudioPlaybackService 保活 FGS。
      try {
        mediaSessionService.startForeground(
            mediaNotification.notificationId,
            mediaNotification.notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
        startedInForeground = true;
        Log.i(
            TAG,
            "startForegroundService rejected, direct startForeground succeeded "
                + "(id=" + mediaNotification.notificationId + ")");
        return;
      } catch (Throwable directError) {
        Log.w(
            TAG,
            "direct startForeground rejected, fallback to notify(): "
                + directError.getMessage(),
            directError);
      }
      try {
        notificationManagerCompat.notify(
            mediaNotification.notificationId, mediaNotification.notification);
      } catch (Throwable notifyError) {
        Log.w(
            TAG,
            "notify() fallback failed: " + notifyError.getMessage(),
            notifyError);
      }
      return;
    }
    Util.setForegroundServiceNotification(
        mediaSessionService,
        mediaNotification.notificationId,
        mediaNotification.notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
        "mediaPlayback");
    startedInForeground = true;
  }

  private void stopForeground(boolean removeNotifications) {
    // To hide the notification on all API levels, we need to call both Service.stopForeground(true)
    // and notificationManagerCompat.cancel(notificationId).
    if (Util.SDK_INT >= 24) {
      Api24.stopForeground(mediaSessionService, removeNotifications);
    } else {
      // For pre-L devices, we must call Service.stopForeground(true) anyway as a workaround
      // that prevents the media notification from being undismissable.
      mediaSessionService.stopForeground(removeNotifications || Util.SDK_INT < 21);
    }
    startedInForeground = false;
  }

  @RequiresApi(24)
  private static class Api24 {

    @DoNotInline
    public static void stopForeground(MediaSessionService service, boolean removeNotification) {
      service.stopForeground(removeNotification ? STOP_FOREGROUND_REMOVE : STOP_FOREGROUND_DETACH);
    }

    private Api24() {}
  }
}
