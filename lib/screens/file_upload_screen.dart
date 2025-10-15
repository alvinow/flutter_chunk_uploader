import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_chunk_uploader/base/chunked_file_uploader.dart';


class FileUploadScreen extends StatefulWidget {
  const FileUploadScreen({Key? key}) : super(key: key);

  @override
  State<FileUploadScreen> createState() => _FileUploadScreenState();
}

class _FileUploadScreenState extends State<FileUploadScreen> {
  ChunkedFileUploader? _uploader;
  UploadProgress? _currentProgress;
  File? _selectedFile;
  Uint8List? _selectedFileBytes;
  String? _selectedFileName;

  @override
  void initState() {
    super.initState();
    _uploader = ChunkedFileUploader(
      serverUrl: 'http://localhost:3000', // Change to your server URL
      chunkSize: 1024 * 1024, // 1MB chunks
    );

    // Listen to progress updates
    _uploader!.progressStream.listen((progress) {
      setState(() {
        _currentProgress = progress;
      });

      // Show completion message
      if (progress.status == UploadStatus.completed) {
        _showMessage('Upload completed successfully!', Colors.green);
      } else if (progress.status == UploadStatus.failed) {
        _showMessage('Upload failed: ${progress.error}', Colors.red);
      } else if (progress.status == UploadStatus.cancelled) {
        _showMessage('Upload cancelled', Colors.orange);
      }
    });
  }

  @override
  void dispose() {
    _uploader?.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();

    if (result != null) {
      if (kIsWeb) {
        // Web: use bytes
        final bytes = result.files.single.bytes;
        if (bytes != null) {
          setState(() {
            _selectedFileBytes = bytes;
            _selectedFileName = result.files.single.name;
            _selectedFile = null;
            _currentProgress = null;
          });
        }
      } else {
        // Mobile: use file path (only access .path on non-web)
        final path = result.files.single.path;
        if (path != null) {
          setState(() {
            _selectedFile = File(path);
            _selectedFileName = result.files.single.name;
            _selectedFileBytes = null;
            _currentProgress = null;
          });
        }
      }
    }
  }

  Future<void> _startUpload() async {
    if (_uploader == null) return;

    try {
      if (kIsWeb) {
        // Web upload
        if (_selectedFileBytes == null || _selectedFileName == null) return;
        await _uploader!.uploadFileFromBytes(_selectedFileBytes!, _selectedFileName!);
      } else {
        // Mobile upload
        if (_selectedFile == null) return;
        await _uploader!.uploadFile(_selectedFile!);
      }
    } catch (e) {
      _showMessage('Error: $e', Colors.red);
    }
  }

  void _pauseUpload() {
    _uploader?.pauseUpload();
  }

  void _resumeUpload() {
    _uploader?.resumeUpload();
  }

  void _cancelUpload() {
    _uploader?.cancelUpload();
    setState(() {
      _currentProgress = null;
    });
  }

  void _showMessage(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  int _getFileSize() {
    if (_selectedFileBytes != null) {
      return _selectedFileBytes!.length;
    }
    if (_selectedFile != null) {
      try {
        return _selectedFile!.lengthSync();
      } catch (e) {
        return 0;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chunked File Upload'),
        elevation: 2,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // File selection card
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select File',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_selectedFileName != null) ...[
                      Row(
                        children: [
                          const Icon(Icons.insert_drive_file, size: 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _selectedFileName!,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  _formatBytes(
                                    _getFileSize(),
                                  ),
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ] else
                      const Text(
                        'No file selected',
                        style: TextStyle(color: Colors.grey),
                      ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose File'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 45),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Progress card
            if (_currentProgress != null) ...[
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Upload Progress',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          _buildStatusChip(_currentProgress!.status),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Progress bar
                      LinearProgressIndicator(
                        value: _currentProgress!.percentage / 100,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),

                      const SizedBox(height: 12),

                      // Progress details
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${_currentProgress!.percentage.toStringAsFixed(1)}%',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            '${_formatBytes(_currentProgress!.uploadedBytes)} / '
                                '${_formatBytes(_currentProgress!.totalBytes)}',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),

                      Text(
                        'Chunks: ${_currentProgress!.uploadedChunks} / '
                            '${_currentProgress!.totalChunks}',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
            ],

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_selectedFile != null || _selectedFileBytes != null) &&
                        (_currentProgress == null ||
                            _currentProgress!.status == UploadStatus.idle)
                        ? _startUpload
                        : null,
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text('Upload'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 50),
                    ),
                  ),
                ),

                if (_currentProgress != null &&
                    _currentProgress!.status == UploadStatus.uploading) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pauseUpload,
                      icon: const Icon(Icons.pause),
                      label: const Text('Pause'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                    ),
                  ),
                ],

                if (_currentProgress != null &&
                    _currentProgress!.status == UploadStatus.paused) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _resumeUpload,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Resume'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                    ),
                  ),
                ],

                if (_currentProgress != null &&
                    (_currentProgress!.status == UploadStatus.uploading ||
                        _currentProgress!.status == UploadStatus.paused)) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _cancelUpload,
                    icon: const Icon(Icons.close),
                    iconSize: 28,
                    color: Colors.red,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(UploadStatus status) {
    Color color;
    String text;
    IconData icon;

    switch (status) {
      case UploadStatus.idle:
        color = Colors.grey;
        text = 'Idle';
        icon = Icons.radio_button_unchecked;
        break;
      case UploadStatus.initializing:
        color = Colors.blue;
        text = 'Initializing';
        icon = Icons.refresh;
        break;
      case UploadStatus.uploading:
        color = Colors.blue;
        text = 'Uploading';
        icon = Icons.cloud_upload;
        break;
      case UploadStatus.paused:
        color = Colors.orange;
        text = 'Paused';
        icon = Icons.pause;
        break;
      case UploadStatus.completed:
        color = Colors.green;
        text = 'Completed';
        icon = Icons.check_circle;
        break;
      case UploadStatus.failed:
        color = Colors.red;
        text = 'Failed';
        icon = Icons.error;
        break;
      case UploadStatus.cancelled:
        color = Colors.grey;
        text = 'Cancelled';
        icon = Icons.cancel;
        break;
    }

    return Chip(
      avatar: Icon(icon, size: 16, color: Colors.white),
      label: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      backgroundColor: color,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}