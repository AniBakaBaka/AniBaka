import 'package:flutter/material.dart';

import 'package:baka/widgets/settings/dlss_effects_editor.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class LabsSettingsPage extends StatelessWidget {
  const LabsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const SettingsPage(title: '实验室', children: [DlssSettings()]);
}
