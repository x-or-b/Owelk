cmake_minimum_required(VERSION 3.24)
project(Owelk VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 6.9 REQUIRED COMPONENTS Quick QuickControls2 Pdf PdfQuick Sql Concurrent PrintSupport Widgets Network WebEngineQuick)
qt_standard_project_setup(REQUIRES 6.9)

qt_add_library(owelk_core STATIC src/ResearchStore.cpp src/ResearchStoreHighlights.cpp src/ResearchStoreRelink.cpp src/ResearchStoreWorkspaces.cpp src/ResearchStoreSearch.cpp src/ResearchStoreDocuments.cpp src/ResearchStoreLibrary.cpp src/ResearchStoreNotes.cpp src/PaperMetadata.cpp src/PaperMetadata.h src/MetadataLookup.cpp src/MetadataLookup.h src/ai/AiService.cpp src/ai/AiService.h src/ai/AiProviders.cpp src/ai/AiProviders.h src/ai/AiContext.cpp src/ai/AiContext.h src/ai/Keychain.cpp src/ai/Keychain.h src/ResearchStore.h src/SelectionGeometry.cpp src/SelectionGeometry.h src/PaperIndex.cpp src/PaperIndex.h src/PdfPrinting.cpp src/PdfPrinting.h src/FileFingerprint.cpp src/FileFingerprint.h src/SchemaMigration.h src/WorkerConnection.h)
target_link_libraries(owelk_core PUBLIC Qt6::Core Qt6::Gui Qt6::Pdf Qt6::Sql Qt6::Concurrent Qt6::PrintSupport Qt6::Widgets Qt6::Network)
target_include_directories(owelk_core PUBLIC src src/ai)
target_sources(owelk_core PRIVATE src/AnnotationImage.cpp src/AnnotationImage.h)
if(APPLE)
    target_link_libraries(owelk_core PUBLIC "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation" "-framework Security")
endif()

qt_add_executable(owelk MACOSX_BUNDLE src/main.cpp)
qt_add_qml_module(owelk
    URI Owelk VERSION 1.0
    QML_FILES qml/SearchFilters.qml qml/CaptureNoteDialog.qml qml/WorkspaceManager.qml qml/UiTheme.js qml/RoundedSurface.qml qml/UiControls.qml qml/ReaderIconButton.qml qml/AnnotationColors.qml qml/AnnotationEditor.qml
    QML_FILES qml/Main.qml qml/ReaderPane.qml qml/PdfCanvas.qml qml/CaptureShelf.qml qml/CommandPalette.qml qml/FilePanel.qml qml/DockSidebar.qml qml/HomeView.qml qml/StatusIcon.qml qml/DocumentWorkspace.qml qml/DocumentGroup.qml qml/WorkspaceTree.js qml/RecentPaperDelegate.qml qml/PaletteMatch.js qml/StrokePath.js qml/SearchPalette.qml qml/PdfNavigationPanel.qml qml/ResearchSearch.qml qml/SearchResultDelegate.qml qml/IndexStatus.qml qml/RelinkDialog.qml qml/PaperDetailsDialog.qml qml/WebPane.qml qml/SettingsDialog.qml qml/LibraryView.qml qml/NotePane.qml qml/LinkToNoteDialog.qml qml/AiComposer.qml
)
target_link_libraries(owelk PRIVATE owelk_core Qt6::Quick Qt6::QuickControls2 Qt6::PdfQuick Qt6::WebEngineQuick)
set_target_properties(owelk PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME Owelk
    MACOSX_BUNDLE_GUI_IDENTIFIER org.owelk.reader
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    WIN32_EXECUTABLE TRUE
)

include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 REQUIRED COMPONENTS Test QuickTest)
    qt_add_executable(owelk_tests tests/ResearchStoreTest.cpp)
    target_link_libraries(owelk_tests PRIVATE owelk_core Qt6::Test)
    add_test(NAME store_and_pdf COMMAND owelk_tests)
    set_tests_properties(store_and_pdf PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    qt_add_executable(owelk_index_tests tests/PaperIndexTest.cpp)
    target_link_libraries(owelk_index_tests PRIVATE owelk_core Qt6::Test)
    add_test(NAME paper_index COMMAND owelk_index_tests)
    set_tests_properties(paper_index PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    qt_add_executable(owelk_relink_tests tests/RelinkTest.cpp)
    target_link_libraries(owelk_relink_tests PRIVATE owelk_core Qt6::Test)
    add_test(NAME source_relink COMMAND owelk_relink_tests)
    set_tests_properties(source_relink PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    qt_add_executable(owelk_text_capture_tests tests/TextCaptureTest.cpp)
    target_link_libraries(owelk_text_capture_tests PRIVATE owelk_core Qt6::Test)
    add_test(NAME text_captures COMMAND owelk_text_capture_tests)
    set_tests_properties(text_captures PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    qt_add_executable(owelk_ai_tests tests/AiTest.cpp)
    target_link_libraries(owelk_ai_tests PRIVATE owelk_core Qt6::Test)
    target_compile_definitions(owelk_ai_tests PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME ai_providers COMMAND owelk_ai_tests)
    set_tests_properties(ai_providers PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    qt_add_executable(owelk_fixtures tests/fixtures.cpp)
    target_link_libraries(owelk_fixtures PRIVATE Qt6::Gui)
    qt_add_executable(owelk_ui_tests tests/ReaderUiTest.cpp)
    target_link_libraries(owelk_ui_tests PRIVATE owelk_core Qt6::QuickTest Qt6::QuickControls2 Qt6::PdfQuick Qt6::WebEngineQuick Qt6::Network)
    target_compile_definitions(owelk_ui_tests PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME reader_interactions COMMAND owelk_ui_tests)
    set_tests_properties(reader_interactions PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software")
endif()
