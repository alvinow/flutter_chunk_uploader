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

  UploadProgress({
    required this.uploadedChunks,
    required this.totalChunks,
    required this.uploadedBytes,
    required this.totalBytes,
    required this.percentage,
    required this.status,
    this.error,
  });

  UploadProgress copyWith({
    int? uploadedChunks,
    int? totalChunks,
    int? uploadedBytes,
    int? totalBytes,
    double? percentage,
    UploadStatus? status,
    String? error,
  }) {
    return UploadProgress(
      uploadedChunks: uploadedChunks ?? this.uploadedChunks,
      totalChunks: totalChunks ?? this.totalChunks,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      percentage: percentage ?? this.percentage,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }
}

/// Chunked file uploader service - supports mobile and web
class ChunkedFileUploader {
  final String serverUrl;
  final Dio _dio;
  final int chunkSize;

  String? _uploadId;
  bool _isPaused = false;
  bool _isCancelled = false;

  final StreamController<UploadProgress> _progressController =
  StreamController<UploadProgress>.broadcast();

  Stream<UploadProgress> get progressStream => _progressController.stream;

  ChunkedFileUploader({
    required this.serverUrl,
    this.chunkSize = 1024 * 1024, // 1MB default chunk size
    int connectionTimeout = 30000,
    int receiveTimeout = 30000,
  }) : _dio = Dio(
    BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: Duration(milliseconds: connectionTimeout),
      receiveTimeout: Duration(milliseconds: receiveTimeout),
    ),
  );

  /// Upload a file from bytes (works on web and mobile)
  Future<String?> uploadFileFromBytes(
      Uint8List bytes,
      String filename, {
        Map<String, dynamic>? metadata,
        bool resumable = true,
      }) async {
    try {
      _isCancelled = false;
      _isPaused = false;

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
        }
      }

      // Upload chunks
      int uploadedBytes = (totalChunks - missingChunks.length) * chunkSize;

      for (int chunkNumber in missingChunks) {
        if (_isCancelled) {
          await cancelUpload();
          _emitProgress(UploadProgress(
            uploadedChunks: totalChunks - missingChunks.length,
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

        final success = await _uploadChunkFromBytes(
          bytes,
          chunkNumber,
          totalChunks,
          fileSize,
        );

        if (success) {
          final chunkBytes = _getChunkSize(chunkNumber, totalChunks, fileSize);
          uploadedBytes += chunkBytes;

          _emitProgress(UploadProgress(
            uploadedChunks: totalChunks - missingChunks.length +
                missingChunks.indexOf(chunkNumber) + 1,
            totalChunks: totalChunks,
            uploadedBytes: uploadedBytes,
            totalBytes: fileSize,
            percentage: (uploadedBytes / fileSize) * 100,
            status: _isPaused ? UploadStatus.paused : UploadStatus.uploading,
          ));
        } else {
          throw Exception('Failed to upload chunk $chunkNumber');
        }
      }

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

      return result?['filename'];
    } catch (e) {
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

    try {
      _isCancelled = false;
      _isPaused = false;

      final fileSize = await file.length();
      final filename = path.basename(file.path);
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
        }
      }

      // Upload chunks
      int uploadedBytes = (totalChunks - missingChunks.length) * chunkSize;

      for (int chunkNumber in missingChunks) {
        if (_isCancelled) {
          await cancelUpload();
          _emitProgress(UploadProgress(
            uploadedChunks: totalChunks - missingChunks.length,
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

        final success = await _uploadChunk(
          file,
          chunkNumber,
          totalChunks,
          fileSize,
        );

        if (success) {
          final chunkBytes = _getChunkSize(chunkNumber, totalChunks, fileSize);
          uploadedBytes += chunkBytes;

          _emitProgress(UploadProgress(
            uploadedChunks: totalChunks - missingChunks.length +
                missingChunks.indexOf(chunkNumber) + 1,
            totalChunks: totalChunks,
            uploadedBytes: uploadedBytes,
            totalBytes: fileSize,
            percentage: (uploadedBytes / fileSize) * 100,
            status: _isPaused ? UploadStatus.paused : UploadStatus.uploading,
          ));
        } else {
          throw Exception('Failed to upload chunk $chunkNumber');
        }
      }

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

      return result?['filename'];
    } catch (e) {
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
        },
      );

      return response.data['uploadId'];
    } catch (e) {
      print('Initialize upload error: $e');
      return null;
    }
  }

  /// Upload a single chunk from File
  Future<bool> _uploadChunk(
      File file,
      int chunkNumber,
      int totalChunks,
      int fileSize,
      ) async {
    try {
      final start = chunkNumber * chunkSize;
      final end = (start + chunkSize < fileSize) ? start + chunkSize : fileSize;

      final chunk = await file.openRead(start, end).toList();
      final chunkBytes = chunk.expand((x) => x).toList();

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
      );

      return response.statusCode == 200;
    } catch (e) {
      print('Upload chunk error: $e');
      return false;
    }
  }

  /// Upload a single chunk from bytes
  Future<bool> _uploadChunkFromBytes(
      Uint8List bytes,
      int chunkNumber,
      int totalChunks,
      int fileSize,
      ) async {
    try {
      final start = chunkNumber * chunkSize;
      final end = (start + chunkSize < fileSize) ? start + chunkSize : fileSize;

      final chunkBytes = bytes.sublist(start, end);

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
      );

      return response.statusCode == 200;
    } catch (e) {
      print('Upload chunk error: $e');
      return false;
    }
  }

  /// Complete upload and merge chunks
  Future<Map<String, dynamic>?> _completeUpload() async {
    try {
      final response = await _dio.post(
        '/upload/complete',
        data: {'uploadId': _uploadId},
      );

      return response.data;
    } catch (e) {
      print('Complete upload error: $e');
      return null;
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
    if (_uploadId == null) return;

    _isCancelled = true;

    try {
      await _dio.delete('/upload/$_uploadId');
    } catch (e) {
      print('Cancel upload error: $e');
    }

    _uploadId = null;
  }

  /// Pause upload
  void pauseUpload() {
    _isPaused = true;
    _emitProgress(UploadProgress(
      uploadedChunks: 0,
      totalChunks: 0,
      uploadedBytes: 0,
      totalBytes: 0,
      percentage: 0.0,
      status: UploadStatus.paused,
    ));
  }

  /// Resume upload
  void resumeUpload() {
    _isPaused = false;
  }

  /// Get chunk size for a specific chunk
  int _getChunkSize(int chunkNumber, int totalChunks, int fileSize) {
    if (chunkNumber == totalChunks - 1) {
      return fileSize - (chunkNumber * chunkSize);
    }
    return chunkSize;
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