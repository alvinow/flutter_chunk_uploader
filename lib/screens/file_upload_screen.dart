import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_chunk_uploader/base/chunked_file_uploader.dart';


class FileUploadScreen extends StatefulWidget {
  const FileUploadScreen({Key? key}) : super(key: key);

  @override
  State<FileUploadScreen> createState() => _FileUploadScreenState();
}

class _FileUploadScreenState extends State<FileUploadScreen> {
  final ChunkedFileUploader _uploader = ChunkedFileUploader(
    serverUrl: 'http://localhost:3000',
    parallelUploads: 3,
  );

  UploadProgress? _currentProgress;
  String? _selectedFileName;
  PlatformFile? _selectedFile;

  @override
  void initState() {
    super.initState();
    _uploader.progressStream.listen((progress) {
      setState(() {
        _currentProgress = progress;
      });
    });
  }

  @override
  void dispose() {
    _uploader.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFile = result.files.first;
          _selectedFileName = result.files.first.name;
          _currentProgress = null;
        });
      }
    } catch (e) {
      _showError('Failed to pick file: $e');
    }
  }

  Future<void> _uploadFile() async {
    if (_selectedFile == null) {
      _showError('Please select a file first');
      return;
    }

    try {
      final bytes = _selectedFile!.bytes;
      if (bytes == null) {
        _showError('Could not read file bytes');
        return;
      }

      final filename = await _uploader.uploadFileFromBytes(
        bytes,
        _selectedFile!.name,
        resumable: true,
      );

      if (filename != null) {
        _showSuccess('File uploaded successfully: $filename');
      }
    } catch (e) {
      _showError('Upload failed: $e');
    }
  }

  void _pauseUpload() {
    _uploader.pauseUpload();
  }

  void _resumeUpload() {
    _uploader.resumeUpload();
  }

  void _cancelUpload() {
    _uploader.cancelUpload();
    setState(() {
      _currentProgress = null;
      _selectedFile = null;
      _selectedFileName = null;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
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

  String _formatSpeed(double? bytesPerSecond) {
    if (bytesPerSecond == null) return 'Calculating...';
    return '${_formatBytes(bytesPerSecond.toInt())}/s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chunked File Upload'),
        backgroundColor: Colors.blue,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // File Selection Card
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.cloud_upload,
                        size: 64,
                        color: Colors.blue,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Select File'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                      ),
                      if (_selectedFileName != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Selected: $_selectedFileName',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_selectedFile != null)
                          Text(
                            'Size: ${_formatBytes(_selectedFile!.size)}',
                            style: TextStyle(
                              color: Colors.grey[600],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Upload Progress Card
              if (_currentProgress != null) ...[
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Text(
                          _getStatusText(_currentProgress!.status),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: _currentProgress!.percentage / 100,
                          minHeight: 10,
                          backgroundColor: Colors.grey[300],
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _getStatusColor(_currentProgress!.status),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_currentProgress!.percentage.toStringAsFixed(1)}%',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              children: [
                                const Text('Chunks'),
                                Text(
                                  '${_currentProgress!.uploadedChunks}/${_currentProgress!.totalChunks}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              children: [
                                const Text('Data'),
                                Text(
                                  '${_formatBytes(_currentProgress!.uploadedBytes)}/${_formatBytes(_currentProgress!.totalBytes)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (_currentProgress!.speedBytesPerSecond != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Speed: ${_formatSpeed(_currentProgress!.speedBytesPerSecond)}',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                        ],
                        if (_currentProgress!.error != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.red[50],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _currentProgress!.error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Control Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _selectedFile != null &&
                          (_currentProgress == null ||
                              _currentProgress!.status ==
                                  UploadStatus.failed)
                          ? _uploadFile
                          : null,
                      icon: const Icon(Icons.upload),
                      label: const Text('Upload'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_currentProgress != null &&
                      _currentProgress!.status == UploadStatus.uploading)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _pauseUpload,
                        icon: const Icon(Icons.pause),
                        label: const Text('Pause'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  if (_currentProgress != null &&
                      _currentProgress!.status == UploadStatus.paused)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _resumeUpload,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Resume'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  if (_currentProgress != null &&
                      (_currentProgress!.status == UploadStatus.uploading ||
                          _currentProgress!.status == UploadStatus.paused))
                    const SizedBox(width: 8),
                  if (_currentProgress != null &&
                      (_currentProgress!.status == UploadStatus.uploading ||
                          _currentProgress!.status == UploadStatus.paused))
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _cancelUpload,
                        icon: const Icon(Icons.cancel),
                        label: const Text('Cancel'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getStatusText(UploadStatus status) {
    switch (status) {
      case UploadStatus.idle:
        return 'Ready to Upload';
      case UploadStatus.initializing:
        return 'Initializing Upload...';
      case UploadStatus.uploading:
        return 'Uploading...';
      case UploadStatus.paused:
        return 'Upload Paused';
      case UploadStatus.completed:
        return 'Upload Completed!';
      case UploadStatus.failed:
        return 'Upload Failed';
      case UploadStatus.cancelled:
        return 'Upload Cancelled';
    }
  }

  Color _getStatusColor(UploadStatus status) {
    switch (status) {
      case UploadStatus.uploading:
      case UploadStatus.initializing:
        return Colors.blue;
      case UploadStatus.paused:
        return Colors.orange;
      case UploadStatus.completed:
        return Colors.green;
      case UploadStatus.failed:
      case UploadStatus.cancelled:
        return Colors.red;
      case UploadStatus.idle:
        return Colors.grey;
    }
  }
}