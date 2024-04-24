# Secure File Deletion Tool

This PowerShell script provides a graphical user interface (GUI) to securely delete files using different algorithms. It allows users to select files from their system and choose between two deletion algorithms: Gutmann Algorithm and DoD 5220-22.M Algorithm.

## How to Use

1. **Select Files**: Click on the "Select" button to choose the files you want to securely delete. You can select multiple files using the file dialog.

2. **Select Deletion Algorithm**: Choose the deletion algorithm from the dropdown menu. You can choose between the Gutmann Algorithm and the DoD 5220-22.M Algorithm.

3. **Number of Iterations (Gutmann Algorithm Only)**: If you choose the Gutmann Algorithm, you can select the number of overwrite iterations using the numeric up-down control. This option is disabled when the DoD 5220-22.M Algorithm is selected.

4. **Delete**: Click on the "Delete" button to securely delete the selected files using the chosen algorithm.

5. **Progress Messages**: Progress messages will be displayed in the text box at the bottom of the window, indicating the status of the deletion process.

## Algorithms

### Gutmann Algorithm

The Gutmann Algorithm is a secure file deletion method that overwrites the file's data 35 times with carefully selected patterns of data. This method was originally proposed by Peter Gutmann in 1996 and is known for its thoroughness in data destruction.

### DoD 5220-22.M Algorithm

The DoD 5220-22.M Algorithm is a standard for file deletion defined by the United States Department of Defense. It involves overwriting the file's data three times with specific patterns, ensuring that the original data cannot be recovered easily.

## Requirements

- Windows operating system
- PowerShell

## Disclaimer

This script is provided for educational purposes only. Use it responsibly and ensure that you have the necessary permissions before deleting any files.

