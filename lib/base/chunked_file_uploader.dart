import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/foundation.dart';

/// Upload status enum
enum UploadStatus {
  idle,
  initializing,
  uploading,
  paused,
  completed,
  failed,
  cancelled
}

/// Upload progress model
class UploadProgress {
  final int uploadedChunks;
  final int totalChunks;
  final int uploadedBytes;
  final int totalBytes;
  final double percentage;
  final UploadStatus status;
  final String? error;
  final double? speedBytesPerSecond;

  UploadProgress({
    required this.uploadedChunks,
    required this.totalChunks,
    required this.uploadedBytes,
    required this.totalBytes,
    required this.percentage,
    required this.status,
    this.error,
    this.speedBytesPerSecond,
  });

  UploadProgress copyWith({
    int? uploadedChunks,
    int? totalChunks,
    int? uploadedBytes,
    int? totalBytes,
    double? percentage,
    UploadStatus? status,
    String? error,
    double? speedBytesPerSecond,
  }) {
    return UploadProgress(
      uploadedChunks: uploadedChunks ?? this.uploadedChunks,
      totalChunks: totalChunks ?? this.totalChunks,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      percentage: percentage ?? this.percentage,
      status: status ?? this.status,
      error: error ?? this.error,
      speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    );
  }
}

/// Chunked file uploader service - supports mobile and web
class ChunkedFileUploader {
  final String serverUrl;
  final Dio _dio;
  int chunkSize;
  int parallelUploads;

  String? _uploadId;
  bool _isPaused = false;
  bool _isCancelled = false;
  static const int _maxRetries = 3;

  // Speed tracking
  DateTime? _uploadStartTime;
  int _lastUploadedBytes = 0;

  final StreamController<UploadProgress> _progressController =
  StreamController<UploadProgress>.broadcast();

  Stream<UploadProgress> get progressStream => _progressController.stream;

  ChunkedFileUploader({
    required this.serverUrl,
    int? chunkSize,
    this.parallelUploads = 3,
    int connectionTimeout = 30000,
    int receiveTimeout = 30000,
  })  : chunkSize = chunkSize ?? (5 * 1024 * 1024),
        _dio = Dio(
          BaseOptions(
            baseUrl: serverUrl,
            connectTimeout: Duration(milliseconds: connectionTimeout),
            receiveTimeout: Duration(milliseconds: receiveTimeout),
          ),
        );

  /// Upload a file from bytes (works on web and mobile) with parallel chunks
  Future<String?> uploadFileFromBytes(
      Uint8List bytes,
      String filename, {
        Map<String, dynamic>? metadata,
        bool resumable = true,
      }) async {
    try {
      _isCancelled = false;
      _isPaused = false;
      _uploadStartTime = DateTime.now();
      _lastUploadedBytes = 0;

      final fileSize = bytes.length;
      final totalChunks = (fileSize / chunkSize).ceil();

      _emitProgress(UploadProgress(
        uploadedChunks: 0,
        totalChunks: totalChunks,
        uploadedBytes: 0,
        totalBytes: fileSize,
        percentage: 0.0,
        status: UploadStatus.initializing,
      ));

      // Initialize upload session
      _uploadId = await _initializeUpload(filename, totalChunks, fileSize);
      if (_uploadId == null) {
        throw Exception('Failed to initialize upload');
      }

      print('Upload initialized with ID: $_uploadId');

      _emitProgress(UploadProgress(
        uploadedChunks: 0,
        totalChunks: totalChunks,
        uploadedBytes: 0,
        totalBytes: fileSize,
        percentage: 0.0,
        status: UploadStatus.uploading,
      ));

      // Check for existing chunks if resumable
      List<int> missingChunks = List.generate(totalChunks, (i) => i);
      if (resumable && _uploadId != null) {
        final status = await getUploadStatus(_uploadId!);
        if (status != null && status['missingChunks'] != null) {
          missingChunks = List<int>.from(status['missingChunks']);
          print('Resuming upload: ${missingChunks.length} chunks remaining');
        }
      }

      // Upload chunks in parallel
      final uploadedChunkIndices = <int>{};
      int chunkIndex = 0;

      while (chunkIndex < missingChunks.length) {
        if (_isCancelled) {
          await _cleanupUpload();
          final uploadedBytes = _calculateUploadedBytes(
              uploadedChunkIndices, totalChunks, fileSize);
          _emitProgress(UploadProgress(
            uploadedChunks: uploadedChunkIndices.length,
            totalChunks: totalChunks,
            uploadedBytes: uploadedBytes,
            totalBytes: fileSize,
            percentage: (uploadedBytes / fileSize) * 100,
            status: UploadStatus.cancelled,
          ));
          return null;
        }

        // Wait if paused
        while (_isPaused && !_isCancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        // Upload up to 'parallelUploads' chunks simultaneously
        final parallelTasks = <Future<bool>>[];
        final parallelChunkNumbers = <int>[];

        for (int i = 0;
        i < parallelUploads && chunkIndex < missingChunks.length;
        i++) {
          final chunkNumber = missingChunks[chunkIndex];
          parallelChunkNumbers.add(chunkNumber);
          parallelTasks.add(_uploadChunkFromBytes(
            bytes,
            chunkNumber,
            totalChunks,
            fileSize,
          ));
          chunkIndex++;
        }

        // Wait for all parallel uploads to complete
        final results = await Future.wait(parallelTasks);

        // Check results and update progress
        for (int i = 0; i < results.length; i++) {
          if (results[i]) {
            uploadedChunkIndices.add(parallelChunkNumbers[i]);
          }
        }

        // Calculate accurate progress with speed tracking
        final uploadedBytes = _calculateUploadedBytes(
            uploadedChunkIndices, totalChunks, fileSize);
        final speed = _calculateUploadSpeed(uploadedBytes);

        _emitProgress(UploadProgress(
          uploadedChunks: uploadedChunkIndices.length,
          totalChunks: totalChunks,
          uploadedBytes: uploadedBytes,
          totalBytes: fileSize,
          percentage: (uploadedBytes / fileSize) * 100,
          status: _isPaused ? UploadStatus.paused : UploadStatus.uploading,
          speedBytesPerSecond: speed,
        ));

        // If any chunk failed, throw error with details
        final failedChunks = <int>[];
        for (int i = 0; i < results.length; i++) {
          if (!results[i]) {
            failedChunks.add(parallelChunkNumbers[i]);
          }
        }

        if (failedChunks.isNotEmpty) {
          print('Failed chunks: $failedChunks');

          // Check server status for debugging
          if (_uploadId != null) {
            final status = await getUploadStatus(_uploadId!);
            print('Server status: $status');
          }

          throw Exception(
              'Failed to upload chunks: ${failedChunks.join(', ')}');
        }
      }

      // Verify all chunks before completing
      await _verifyUploadComplete();

      // Complete upload
      final result = await _completeUpload();

      _emitProgress(UploadProgress(
        uploadedChunks: totalChunks,
        totalChunks: totalChunks,
        uploadedBytes: fileSize,
        totalBytes: fileSize,
        percentage: 100.0,
        status: UploadStatus.completed,
      ));

      print('Upload completed successfully: ${result?['filename']}');
      return result?['filename'];
    } catch (e) {
      print('Upload failed: $e');
      await _cleanupUpload();
      _emitProgress(UploadProgress(
        uploadedChunks: 0,
        totalChunks: 0,
        uploadedBytes: 0,
        totalBytes: 0,
        percentage: 0.0,
        status: UploadStatus.failed,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  /// Upload a file from File object (mobile only)
  Future<String?> uploadFile(
      File file, {
        Map<String, dynamic>? metadata,
        bool resumable = true,
      }) async {
    if (kIsWeb) {
      throw Exception('Use uploadFileFromBytes for web platform');
    }

    final bytes = await file.readAsBytes();
    final filename = path.basename(file.path);
    return uploadFileFromBytes(bytes, filename,
        metadata: metadata, resumable: resumable);
  }

  /// Initialize upload session
  Future<String?> _initializeUpload(
      String filename,
      int totalChunks,
      int fileSize,
      ) async {
    try {
      final response = await _dio.post(
        '/upload/init',
        data: {
          'filename': filename,
          'totalChunks': totalChunks,
          'fileSize': fileSize,
          'chunkSize': chunkSize,
        },
      );

      if (response.data == null || response.data['uploadId'] == null) {
        throw Exception('Server did not return uploadId');
      }

      return response.data['uploadId'];
    } catch (e) {
      print('Initialize upload error: $e');
      throw Exception('Failed to initialize upload: $e');
    }
  }

  /// Upload a single chunk from bytes with retry logic
  Future<bool> _uploadChunkFromBytes(
      Uint8List bytes,
      int chunkNumber,
      int totalChunks,
      int fileSize,
      ) async {
    int retryCount = 0;
    while (retryCount < _maxRetries) {
      try {
        final start = chunkNumber * chunkSize;
        final end = (start + chunkSize < fileSize) ? start + chunkSize : fileSize;
        final chunkBytes = bytes.sublist(start, end);

        print('Uploading chunk $chunkNumber (${chunkBytes.length} bytes)');

        final formData = FormData.fromMap({
          'chunk': MultipartFile.fromBytes(
            chunkBytes,
            filename: 'chunk',
          ),
          'uploadId': _uploadId,
          'chunkNumber': chunkNumber.toString(),
        });

        final response = await _dio.post(
          '/upload/chunk',
          data: formData,
          options: Options(
            validateStatus: (status) => status! < 500,
          ),
        );

        if (response.statusCode == 200) {
          print('Chunk $chunkNumber uploaded successfully');
          return true;
        } else {
          print('Chunk $chunkNumber failed with status ${response.statusCode}: ${response.data}');
          retryCount++;
        }
      } catch (e) {
        retryCount++;
        print('Chunk $chunkNumber upload attempt $retryCount failed: $e');

        if (retryCount >= _maxRetries) {
          print('Max retries reached for chunk $chunkNumber');
          return false;
        }
        // Exponential backoff: wait 1s, 2s, 4s
        await Future.delayed(Duration(seconds: 1 << (retryCount - 1)));
      }
    }
    return false;
  }

  /// Verify all chunks are uploaded before completing
  Future<void> _verifyUploadComplete() async {
    if (_uploadId == null) {
      throw Exception('No upload ID available');
    }

    final status = await getUploadStatus(_uploadId!);
    if (status == null) {
      throw Exception('Could not verify upload status');
    }

    final missingChunks = status['missingChunks'] as List?;
    if (missingChunks != null && missingChunks.isNotEmpty) {
      throw Exception(
          'Cannot complete: Missing chunks $missingChunks. Received: ${status['receivedChunks']}/${status['totalChunks']}');
    }

    print('Upload verification successful: All chunks received');
  }

  /// Complete upload and merge chunks
  Future<Map<String, dynamic>?> _completeUpload() async {
    if (_uploadId == null) {
      throw Exception('No upload ID available');
    }

    try {
      print('Completing upload: $_uploadId');

      final response = await _dio.post(
        '/upload/complete',
        data: {'uploadId': _uploadId},
        options: Options(
          validateStatus: (status) => status! < 500,
        ),
      );

      if (response.statusCode != 200) {
        throw Exception(
            'Server returned ${response.statusCode}: ${response.data}');
      }

      return response.data;
    } catch (e) {
      print('Complete upload error: $e');
      throw Exception('Failed to complete upload: $e');
    }
  }

  /// Get upload status
  Future<Map<String, dynamic>?> getUploadStatus(String uploadId) async {
    try {
      final response = await _dio.get('/upload/status/$uploadId');
      return response.data;
    } catch (e) {
      print('Get status error: $e');
      return null;
    }
  }

  /// Cancel current upload
  Future<void> cancelUpload() async {
    _isCancelled = true;
    await _cleanupUpload();
  }

  /// Cleanup upload on server
  Future<void> _cleanupUpload() async {
    if (_uploadId == null) return;

    try {
      await _dio.delete('/upload/$_uploadId');
      print('Upload cleaned up: $_uploadId');
    } catch (e) {
      print('Cleanup error: $e');
    }

    _uploadId = null;
  }

  /// Pause upload
  void pauseUpload() {
    _isPaused = true;
  }

  /// Resume upload
  void resumeUpload() {
    _isPaused = false;
  }

  /// Calculate accurate uploaded bytes considering last chunk size
  int _calculateUploadedBytes(
      Set<int> uploadedChunks, int totalChunks, int fileSize) {
    int totalBytes = 0;
    for (int chunkNum in uploadedChunks) {
      totalBytes += _getChunkSize(chunkNum, totalChunks, fileSize);
    }
    return totalBytes;
  }

  /// Get chunk size for a specific chunk
  int _getChunkSize(int chunkNumber, int totalChunks, int fileSize) {
    if (chunkNumber == totalChunks - 1) {
      return fileSize - (chunkNumber * chunkSize);
    }
    return chunkSize;
  }

  /// Calculate upload speed
  double? _calculateUploadSpeed(int currentBytes) {
    if (_uploadStartTime == null) return null;

    final elapsed = DateTime.now().difference(_uploadStartTime!);
    if (elapsed.inSeconds == 0) return null;

    final bytesUploaded = currentBytes - _lastUploadedBytes;
    _lastUploadedBytes = currentBytes;

    return bytesUploaded / elapsed.inSeconds;
  }

  /// Emit progress update
  void _emitProgress(UploadProgress progress) {
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }

  /// Dispose resources
  void dispose() {
    _progressController.close();
    _dio.close();
  }
}