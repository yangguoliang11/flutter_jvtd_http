import 'dart:async';
import 'package:meta/meta.dart';

import 'jvtd_http_utils.dart';
import 'jvtd_print_utils.dart';

/// [Api]返回的数据包装类
///
/// 包含响应的全部数据，[T]类型的业务数据实例，[success]表示成功失败，
/// [message]服务响应的消息，http响应码[httpCode]，请求传入的参数[params],
/// 服务正真有用的数据对象[result]。
class HttpData<T> {
  /// 本次服务成功失败标志
  bool _success = false;

  /// 服务响应消息
  String _message;

  /// http响应码
  int _httpCode = 0;

  // 接口返回状态码
  dynamic _statusCode;

  /// 任务传入参数列表
  Map<String, dynamic> _params;

  /// 任务结果数据
  T _result;

  /// 任务取消标志
  bool _cancel = false;

  /// 判断本次服务请求是否成功(用户接口协议约定的请求结果，并非http的请求结果，但是http请求失败时该值总是返回false)
  bool get success => _success;

  /// 获取本次请求返回的结果消息(用户接口协议中约定的消息或者根据规则生成的本地信息，并非http响应消息）
  String get message => _message;

  /// 获取本次http请求返回的响应码
  int get httpCode => _httpCode;

  /// 获取任务传入的参数列表
  Map<String, dynamic> get params => _params;

  /// 获取处理完成的最终结果数据(用户接口协议中定义的有效数据转化成的本地类)
  T get result => _result;

  /// 任务是否被取消
  bool get cancel => _cancel;

  // 获取接口状态码
  dynamic get statusCode => _statusCode;
}

/// 网络请求工具
const JvtdHttpUtils httpUtils = JvtdHttpUtils();

/// 任务流程的基本模型
///
/// [D]为关联的接口结果数据类型，[T]为接口响应包装类型[HttpData]
abstract class Api<D, T extends HttpData<D>> {
  /// 日志标签
  String _tag;

  /// 日志标签
  String get tag => _tag ?? _createTag();

  /// 创建日志标签
  String _createTag() {
    _tag = '$runtimeType@${hashCode.toRadixString(16)}';
    return _tag;
  }

  /// 任务取消状态标签
  bool _cancelMark = false;

  /// 取消请求工具
  final CancelToken _cancelToken = CancelToken();

  /// 启动的任务计数器
  int _counter = 0;

  /// 队尾的任务
  Future<T> _lastFuture;

  /// 启动任务
  ///
  /// * [params]为任务参数列表，[retry]为重试次数，[onProgress]为进度监听器，目前仅上传和下载任务有效。
  /// * 同一个[Api]可以多次启动任务，多次启动的任务会顺序执行。
  Future<T> start({
    Map<String, dynamic> params,
    int retry = 0,
    OnProgress onProgress,
  }) async {
    final counter = ++_counter;

    jvtdLog(tag, "No.$counter api 开始");

    final completer = Completer<T>();
    final lastFuture = _lastFuture;
    _lastFuture = completer.future;

    if (counter > 1) {
      await lastFuture;
    } else {
      _cancelMark = false;
    }

    // 创建数据模型
    final data = onCreateApiData();

    data._params = params == null ? Map() : params;

    // 是否继续执行
    var next = true;

    if (!_cancelMark) {
      // 执行前导任务
      next = onStart(data);
    }

    if (!_cancelMark && next) {
      // 构建http请求选项
      final options = _onCreateOptions(params, retry, onProgress);
      // 执行核心任务
      await _onDo(options, data);
    }

    if (!_cancelMark) {
      // 执行后继任务
      onStop(data);
    }

    if (!_cancelMark) {
      // 最后执行
      jvtdLog(tag, "api完成调用");
      onFinish(data);
    }

    if (_cancelMark) {
      // 任务被取消
      jvtdLog(tag, "api取消调用");
      onCanceled(data);
    }

    jvtdLog(tag, "No.$counter 结束");

    data._cancel = _cancelMark;

    if (--_counter == 0) {
      _lastFuture = null;
    }

    completer.complete(data);

    return completer.future;
  }

  /// 创建数据模型对象的实例
  @protected
  T onCreateApiData();

  /// 任务启动前置方法
  ///
  /// [data]为任务将要返回的数据模型，返回true表示继续执行
  @protected
  @mustCallSuper
  bool onStart(T data) {
    // 校验参数
    if (!onCheckParams(data.params)) {
      // 数据异常
      jvtdLog(tag, "数据异常");
      // 执行异常回调
      data._message = onParamsError(data.params);
      return false;
    }

    return true;
  }

  /// 构建请求选项参数
  Options _onCreateOptions(Map<String, dynamic> params, int retry, OnProgress onProgress) {
    jvtdLog(tag, "构建请求选项参数");

    final data = Map<String, dynamic>();
    onPreFillParams(data, params);
    onFillParams(data, params);

    final options = Options()
      ..retry = retry
      ..onProgress = onProgress
      ..method = httpMethod
      ..headers = onHeaders(params)
      ..params = data
      ..url = onUrl(params);

    onConfigOptions(options, params);

    options.cancelToken = _cancelToken;

    return options;
  }

  /// 核心任务执行
  ///
  /// 此处为真正启动http请求的方法
  Future<void> _onDo(Options options, T data) async {
    if (_cancelMark) {
      return;
    }

    // 创建网络请求工具
    var communication = onInterceptCreateHttpUtils() ?? httpUtils;

    if (_cancelMark) {
      return;
    }

    final response = await communication.request(tag, options);

    if (_cancelMark) {
      return;
    }

    _onParseResponse(response, data);
  }

  /// 任务完成后置方法
  @mustCallSuper
  @protected
  void onStop(T data) {
    jvtdLog(tag, "api调用结束");
    if (!_cancelMark) {
      // 不同结果的后继执行
      if (data.success) {
        jvtdLog(tag, "api调用成功了");
        onSuccess(data);
      } else {
        jvtdLog(tag, "api调用失败了");
        onFailed(data);
      }
    }
  }

  /// 最后执行的一个方法
  ///
  /// 即设置请求结果和返回数据之后，并且在回调任务发送后才执行此函数
  @protected
  void onFinish(T data) {}

  /// 任务被取消时调用
  @protected
  void onCanceled(T data) {}

  /// 参数合法性检测
  ///
  /// * 用于检测传入参数[params]是否合法，需要子类重写检测规则。
  /// * 检测成功任务才会被正常执行，如果检测失败则[onParamsError]会被调用，
  /// 且后续网络请求任务不再执行，任务任然可以正常返回并执行生命周期[onFailed]，[onFinish]。
  /// * 参数合法返回true，非法返回false。
  @protected
  bool onCheckParams(Map<String, dynamic> params) => true;

  /// 参数检测不合法时调用
  ///
  /// * [onCheckParams]返回false时被调用，且后续网络请求任务不再执行，
  /// 但是任务任然可以正常返回并执行生命周期[onFailed]，[onFinish]。
  /// * 返回错误消息内容，将会设置给[HttpData.message]
  @protected
  String onParamsError(Map<String, dynamic> params) => null;

  /// 填充请求所需的前置参数
  ///
  /// * 适合填充项目中所有接口必须传递的固定参数（通过项目中实现的定制[Api]基类完成）
  /// * [data]为请求参数集（http请求要发送的参数），[params]为任务传入的参数列表
  @protected
  void onPreFillParams(Map<String, dynamic> data, Map<String, dynamic> params) {}

  /// 填充请求所需的参数
  ///
  /// [data]为请求参数集（http请求要发送的参数），[params]为任务传入的参数列表
  @protected
  void onFillParams(Map<String, dynamic> data, Map<String, dynamic> params);

  /// 填充请求所需的后置参数
  ///
  /// * 适合对参数进行签名（通过项目中实现的定制[Api]基类完成）
  /// * [data]为请求参数集（http请求要发送的参数），[params]为任务传入的参数列表
  @protected
  void onPostFillParams(Map<String, dynamic> data, Map<String, dynamic> params) {}

  /// 创建并填充请求头
  ///
  /// [params]为任务传入的参数
  @protected
  Map<String, dynamic> onHeaders(Map<String, dynamic> params) => null;

  /// 拦截创建网络请求工具
  ///
  /// * 用于创建完全自定义实现的网络请求工具。
  @protected
  JvtdHttpUtils onInterceptCreateHttpUtils() => null;

  /// 自定义配置http请求选择项
  ///
  /// * [options]为请求将要使用的配置选项，[params]为任务参数
  /// 修改[options]的属性以定制http行为。
  /// * [options]包含[httpMethod]返回的请求方法，
  /// [onFillParams]填充的参数，
  /// [onUrl]返回的请求地址，
  /// [start]中传传递的[retry]和[onProgress]，
  /// [onHeaders]中创建的请求头，
  /// 以上属性都可以在这里被覆盖可以被覆盖。
  @protected
  void onConfigOptions(Options options, Map<String, dynamic> params) {}

  /// 网络请求方法
  @protected
  HttpMethod get httpMethod => HttpMethod.get;

  /// 网络请求完整地址
  ///
  /// [params]任务传入的参数
  @protected
  String onUrl(Map<String, dynamic> params);

  /// 解析响应数据
  void _onParseResponse(Response response, T data) {
    jvtdLog(tag, "开始解析服务器返回数据");
    data._httpCode = response.statusCode;

    if (response.success) {
      // 解析数据
      //noinspection unchecked
      if (_onParse(response.data, data)) {
        // 解析成功
        jvtdLog(tag, "api接口调用完成，进入回调...");
        // 解析成功回调
        onParseSuccess(data);
        if (data.success) {
          jvtdLog(tag, "接口调用正常");
        } else {
          jvtdLog(tag, "接口调用异常");
        }
      } else {
        // 解析失败
        jvtdLog(tag, "数据解析失败");
        // 解析失败回调
        data._message = onParseFailed(data);
      }
    } else if (response.statusCode > 400) {
      // 网络请求失败
      jvtdLog(tag, "网络请求失败");

      // 网络请求失败回调
      data._message = onNetworkRequestFailed(data);
    } else {
      // 网络连接失败
      jvtdLog(tag, "网络连接失败");

      // 网络错误回调
      data._message = onNetworkError(data);
    }
  }

  /// 解析响应体，返回解析结果
  bool _onParse(responseBody, T data) {
    jvtdLog(tag, "解析进行中...");
    if (!onCheckResponse(responseBody)) {
      // 通信异常
      jvtdLog(tag, "校验返回实体异常");
      return false;
    }

    try {
      // 提取服务状态码
      data._statusCode = onResponseCode(responseBody);
      // 提取服务执行结果
      data._success = onResponseResult(responseBody);
      jvtdLog(tag, "分析接口请求结果： " + (data.success ? "成功" : "失败"));

      if (data.success) {
        // 服务请求成功回调
        jvtdLog(tag, "服务器返回成功，进入成功数据解析...");
        data._result = onResponseSuccess(responseBody, data);
        // 提取服务返回的消息
        data._message = onRequestSuccessMessage(responseBody, data);
      } else {
        // 服务请求失败回调
        jvtdLog(tag, "服务器返回失败，进入失败数据解析");
        data._result = onRequestFailed(responseBody, data);
        // 提取服务返回的消息
        data._message = onRequestFailedMessage(responseBody, data);
      }
      jvtdLog(tag, "服务器返回的信息:", data.message);

      return true;
    } catch (e) {
      jvtdLog(tag, "解析异常：", e);
      return false;
    } finally {
      jvtdLog(tag, "解析结束");
    }
  }

  /// 服务器响应数据解析成功后调用
  ///
  /// 即在[_onParse]返回true时调用
  @protected
  void onParseSuccess(T data) {}

  /// 网络请求成功，服务器响应数据解析失败后调用
  ///
  /// 即在[_onParse]返回false时调用，
  /// 返回响应数据解析失败时的消息，即[HttpData.message]字段
  @protected
  String onParseFailed(T data) => null;

  /// 网络连接建立成功，但是请求失败时调用
  ///
  /// 即响应码不是200，返回网络请求失败时的消息，即[HttpData.message]字段
  @protected
  String onNetworkRequestFailed(T data) => null;

  /// 网络连接建立失败时调用，即网络不可用
  ///
  /// 返回设置网络无效时的消息，即[HttpData.message]字段
  @protected
  String onNetworkError(T data) => null;

  /// 检测响应结果是否符合预期（数据类型或是否包含特定字段），也可以做验签
  ///
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  @protected
  bool onCheckResponse(response) => true;

  /// 提取服务执行结果
  ///
  /// * http响应成功，从接口响应的数据中提取本次业务请求真正的成功或失败结果。
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  @protected
  bool onResponseResult(response);

  /// 提取服务之星返回的正确状态码
  @protected
  dynamic onResponseCode(response);

  /// 提取服务执行成功时返回的真正有用结果数据
  ///
  /// * 在服务请求成功后调用，即[onResponseResult]返回值为true时被调用，
  /// 用于生成请求成功后的任务返回真正结果数据对象[D]。
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  @protected
  D onResponseSuccess(response, T data);

  /// 提取或设置服务返回的成功结果消息
  ///
  /// * 在服务请求成功后调用，即[onResponseResult]返回值为true时被调用。
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  @protected
  String onRequestSuccessMessage(response, T data) => null;

  /// 提取或设置服务执行失败时的返回结果数据
  ///
  /// * 在服务请求失败后调用，即[onResponseResult]返回值为false时被调用，
  /// 用于生成请求失败后的任务返回真正结果数据对象[D]，可能是一个默认值。
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  @protected
  D onRequestFailed(response, T data) => null;

  /// 提取或设置服务返回的失败结果消息
  ///
  /// * 在服务请求失败后调用，即[onResponseResult]返回值为false时被调用。
  /// * 通常[response]类型是[onConfigOptions]中设置的[Options.responseType]决定的。
  /// * 在一般请求中默认为[ResponseType.json]则[response]为[Map]类型的json数据。
  /// * 下载请求中默认为[ResponseType.stream]则[response]为[Stream]。
  /// * 如果设置为[ResponseType.plain]则[response]为字符串。
  String onRequestFailedMessage(response, T data) => null;

  /// 本次任务执行成功后执行
  ///
  /// 即设置请求结果和返回数据之后，并且在回调接口之前执行此函数，
  /// 该方法在[onFinish]之前被调用
  @protected
  void onSuccess(T data) {}

  /// 本次任务执行失败后执行
  ///
  /// 即设置请求结果和返回数据之后，并且在回调接口之前执行此函数，
  /// 该方法在[onFinish]之前被调用
  @protected
  void onFailed(T data) {}

  /// 取消正在进行的任务
  ///
  /// 如果本任务被多次启动排队执行，则会一次性取消所有排队任务和正在执行的任务
  void cancel() {
    jvtdLog(tag, "取消本次api调用");
    if (_cancelMark) {
      jvtdLog(tag, "此api调用已取消");
      return;
    }
    if (_counter <= 0) {
      jvtdLog(tag, "此api未开始调用");
      return;
    }
    _cancelMark = true;
    _cancelToken.cancel();
  }
}
