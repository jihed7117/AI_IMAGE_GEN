import Flutter
import UIKit
import os

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let systemChannel = FlutterMethodChannel(
        name: "aiimagegen/system",
        binaryMessenger: controller.binaryMessenger
      )
      systemChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "shareImage":
          guard
            let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            !path.isEmpty
          else {
            result(FlutterError(code: "bad_args", message: "path required", details: nil))
            return
          }
          let url = URL(fileURLWithPath: path)
          let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
          )
          // iPads require a popover anchor or the share sheet crashes.
          if let popover = activityVC.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = controller.view.bounds
          }
          // Ignore taps while a sheet is already up (present() would throw).
          if controller.presentedViewController == nil {
            controller.present(activityVC, animated: true)
            result(true)
          } else {
            result(false)
          }
        case "getStats":
          // Live resource snapshot for the app-bar monitor. Dart samples
          // cpuTimeNanos/wallNanos twice to compute a CPU %.
          let total = ProcessInfo.processInfo.physicalMemory
          var avail: UInt64 = total
          if #available(iOS 13.0, *) {
            let available = os_proc_available_memory()
            if available > 0 {
              avail = UInt64(available)
            }
          }
          result([
            "appRamBytes": appMemoryBytes(),
            "cpuTimeNanos": processCpuTimeNanos(),
            "wallNanos": DispatchTime.now().uptimeNanoseconds,
            "availMem": avail,
            "totalMem": total,
            "lowMemory": false,
          ])
        case "getMemoryInfo":
          // totalMem is the device's physical RAM; availMem is the memory
          // available to this app before jetsam pressure (iOS 13+), falling
          // back to totalMem on older OSes. Used by Dart to refuse loading
          // a model when free memory is insufficient.
          let total = ProcessInfo.processInfo.physicalMemory
          var avail: UInt64 = total
          if #available(iOS 13.0, *) {
            let available = os_proc_available_memory()
            if available > 0 {
              avail = UInt64(available)
            }
          }
          result(["totalMem": total, "availMem": avail, "lowMemory": false])
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// This process's resident memory (physical RAM actually used) in bytes.
  private func appMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let kerr = withUnsafeMutablePointer(to: &info) { ptr in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
        task_info(
          mach_task_self(),
          task_flavor_t(MACH_TASK_BASIC_INFO),
          p,
          &count
        )
      }
    }
    return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }

  /// Total CPU time (user + system, all threads) of this process in
  /// nanoseconds. Compared across two samples by Dart to derive a CPU %.
  private func processCpuTimeNanos() -> UInt64 {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    guard
      task_threads(mach_task_self(), &threadList, &threadCount) == KERN_SUCCESS,
      let threads = threadList
    else {
      return 0
    }
    defer {
      vm_deallocate(
        mach_task_self(),
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
      )
    }
    var total: UInt64 = 0
    for i in 0..<Int(threadCount) {
      var ti = thread_basic_info()
      var tiCount = mach_msg_type_number_t(THREAD_INFO_MAX)
      let res = withUnsafeMutablePointer(to: &ti) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tiCount)) { p in
          thread_info(
            threads[i],
            thread_flavor_t(THREAD_BASIC_INFO),
            p,
            &tiCount
          )
        }
      }
      if res == KERN_SUCCESS && (ti.flags & TH_FLAGS_IDLE) == 0 {
        total += UInt64(ti.user_time.seconds) * 1_000_000_000
          + UInt64(ti.user_time.microseconds) * 1_000
        total += UInt64(ti.system_time.seconds) * 1_000_000_000
          + UInt64(ti.system_time.microseconds) * 1_000
      }
    }
    return total
  }
}
