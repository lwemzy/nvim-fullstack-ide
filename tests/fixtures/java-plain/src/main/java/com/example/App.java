package com.example;

public class App {

	public String greeting() {
		return "hello";
	}

	public static void main(String[] args) {
		System.out.println(new App().greeting());
	}
}
