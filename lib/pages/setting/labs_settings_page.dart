import 'package:flutter/material.dart';

import 'package:baka/widgets/settings/video_enhancement_settings.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class LabsSettingsPage extends StatelessWidget {
  const LabsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const SettingsPage(title: '实验室', children: [VideoEnhancementSettings()]);
}
